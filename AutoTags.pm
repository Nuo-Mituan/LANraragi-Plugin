package LANraragi::Plugin::Metadata::AutoTags;

use strict;
use warnings;
use utf8;

use Mojo::JSON qw(from_json);
use File::Basename;

# 允许使用 LRR 内部 API，但仅使用 Utils 包显式导出的函数
use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging qw(get_plugin_logger);
use LANraragi::Utils::String  qw(trim);
use LANraragi::Utils::Archive qw(is_file_in_archive extract_file_from_archive);
use LANraragi::Utils::Path    qw(open_path_or_die);

# 触发条件：归档的直接父文件夹名
use constant FOLDER_TRANSLATED => 'AI Translated';
use constant FOLDER_GENERATED  => 'AI Generated';

#插件元信息
sub plugin_info {

    return (
        #标准元数据
        name        => "AutoTags",
        type        => "metadata",
        namespace   => "autotags",
        author      => "nuomituan",
        version     => "1.0",
        description =>
          "根据归档的父文件夹名（AI Translated / AI Generated）自动打上对应标签。JSON 元数据（压缩包内嵌 info.json 或同级同名外部文件）仅用于去重判断，绝不直接写入标签：除顶层 language 与 tag 字段外，还支持 nhentai（tags.tag）与 e-hentai（tags.other 等命名空间）两种嵌套结构的等价标签识别；目标标签已存在时不输出任何内容。每次最多只输出一个标签。",
        icon =>
          "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAIAAAAC64paAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAABZSURBVDhPzY5JCgAhDATzSl+e/2irOUjQSFzQog5hhqIl3uBEHPxIXK7oFXwVE+Hj5IYX4lYVtN6MUW4tGw5jNdjdt5bLkwX1q2rFU0/EIJ9OUEm8xquYOQFEhr9vvu2U8gAAAABJRU5ErkJggg==",
        #本插件不需要任何用户参数
        parameters => {}
    );

}

#强制实现的主函数
sub get_tags {

    shift;

    # $lrr_info: LRR 提供的全局信息哈希
    # $params  : LRR 传入的插件参数哈希；本插件无参数，保留以维持 get_tags 的调用约定
    my ( $lrr_info, $params ) = @_;

    my $logger = get_plugin_logger();

    # ---- Step 1: 文件夹精确匹配 ----
    # 取出归档文件的直接父文件夹名（不带任何路径分隔符）
    my ( $folder_name, $archive_name ) = folder_and_archive_name( $lrr_info->{file_path} );

    if ( !$folder_name || ( $folder_name ne FOLDER_TRANSLATED && $folder_name ne FOLDER_GENERATED ) ) {
        $logger->debug( "父文件夹 '" . ( $folder_name // "" ) . "' 不是 AI Translated/AI Generated，跳过。" );
        return ( tags => undef );
    }

    $logger->info("归档位于 '$folder_name' 文件夹，开始处理。");

    # 根据文件夹名确定唯一的默认目标标签：
    # $dedup_candidates 为去重时需检查的等价标签列表（$target_tag 恒为其首项）
    my $target_tag       = "language:AI 汉化";
    my $case_insensitive = 0;
    my @dedup_candidates;

    if ( $folder_name eq FOLDER_GENERATED ) {

        # AI Generated 场景输出固定为中文标签，但去重需兼容 nhentai / e-hentai 两种 JSON 结构
        $target_tag       = "tag:AI生成";
        $case_insensitive = 1;
        @dedup_candidates = ( "tag:AI生成", "tag:ai generated", "other:ai generated" );

    } else {

        # AI Translated 分支逻辑保持原样：精确匹配 language:AI 汉化
        @dedup_candidates = ($target_tag);
    }

    # ---- Step 2: 定位并解析 JSON，仅作为去重依据 ----
    my $json_tags_set = {};

    my ( $json_path, $delete_after_parse ) = find_and_extract_json( $lrr_info->{file_path}, $archive_name, $logger );

    if ($json_path) {

        my $hashjson;

        eval {
            my $stringjson = "";

            # open_path_or_die 内部会打开文件句柄并做兼容处理
            open_path_or_die( my $fh, '<:encoding(UTF-8)', $json_path );

            while ( my $row = <$fh> ) {
                chomp $row;
                $stringjson .= $row;
            }

            close $fh;

            $hashjson = from_json $stringjson;
        };

        if ($@) {
            $logger->warn("JSON 解析失败，视为空集合继续执行：$@");
            $hashjson = undef;
        }

        if ( ref $hashjson eq "HASH" ) {
            $json_tags_set = build_json_tag_set($hashjson);
            $logger->debug( "JSON 去重集合（" . scalar( keys %$json_tags_set ) . " 项）：" . join( ", ", sort keys %$json_tags_set ) );
        } else {
            $logger->warn("JSON 内容不是对象结构，视为空集合继续执行。");
        }

        # 若来自压缩包，处理完毕后必须清理临时文件
        if ( $delete_after_parse && -e $json_path ) {
            unlink $json_path;
        }
    } else {
        $logger->debug("未找到可用的 JSON 文件，去重集合视为空集。");
    }

    # ---- Step 3 & 4: 去重检查与输出控制 ----
    # 任一候选等价标签已存在于 JSON 中，说明其他插件已添加，本插件放弃输出
    for my $dedup_candidate (@dedup_candidates) {

        if ( json_has_tag( $json_tags_set, $dedup_candidate, $case_insensitive ) ) {
            $logger->info("等价标签 '$dedup_candidate' 已存在于 JSON 元数据中，放弃输出。");
            return ();
        }
    }

    # 仅当 JSON 中不存在目标标签时，才将其作为唯一输出返回
    $logger->info("输出标签：$target_tag");

    return ( tags => $target_tag );
}

#folder_and_archive_name($file_path)
#从归档完整路径中取出直接父文件夹名与不带扩展名的归档文件名。
sub folder_and_archive_name {

    my ($file_path) = @_;

    return unless defined $file_path && length $file_path;

    # 结尾的目录分隔符不参与判断
    $file_path =~ s{[\\/]+$}{};

    # 仅需文件名；扩展名由 fileparse 按 qr/\.[^.]*/ 剥离，目录无需接收
    my ( $name, undef, undef ) = fileparse( $file_path, qr/\.[^.]*/ );

    # 仅取直接父文件夹名：路径中必须真的存在分隔符
    my $folder = ( $file_path =~ m{([^\\/]+)[\\/][^\\/]+$} ) ? $1 : undef;

    return ( $folder, $name );
}

#find_and_extract_json($file_path, $archive_name, $logger)
#按固定顺序查找单个 JSON 文件：
#  1. 压缩包内嵌的 info.json
#  2. 同级同名外部文件 ({archive_name}.json)
#返回 ($文件路径, $是否需要删除临时文件)；未找到时返回空。
sub find_and_extract_json {

    my ( $file_path, $archive_name, $logger ) = @_;

    return unless defined $file_path && length $file_path;

    # ---- 步骤 1：查找压缩包内嵌 info.json ----
    # is_file_in_archive 在文件存在时返回归档内的路径字符串，不存在时返回假值
    my $path_in_archive = is_file_in_archive( $file_path, "info.json" );

    if ($path_in_archive) {

        # 提取时第二个参数直接使用返回的归档内路径字符串
        my $extracted = extract_file_from_archive( $file_path, $path_in_archive );

        if ( $extracted && -e $extracted ) {
            $logger->debug("使用压缩包内嵌 JSON：$path_in_archive");
            return ( $extracted, 1 );
        }

        $logger->warn("压缩包内嵌 info.json 提取失败：$path_in_archive");
    }

    # ---- 步骤 2：查找同级同名外部 JSON ----
    # $dir 自带结尾的目录分隔符，可直接拼接
    my ( $name, $dir, undef ) = fileparse( $file_path, qr/\.[^.]*/ );
    my $path_nearby_json = $dir . $name . '.json';

    if ( -e $path_nearby_json ) {
        $logger->debug("使用同级外部 JSON：$path_nearby_json");
        return ( $path_nearby_json, 0 );
    }

    return;
}

#add_tags_to_set($json_tags_set, $prefix, $value)
#把标签值（字符串或数组）trim 后补全命名空间前缀，写入去重集合（键统一小写）。
sub add_tags_to_set {

    my ( $json_tags_set, $prefix, $value ) = @_;

    return unless defined $value;
    return if ref $value eq "HASH";

    my @members = ref $value eq "ARRAY" ? @$value : ($value);

    for my $member (@members) {

        next unless defined $member;
        next if ref $member;

        my $tag = trim($member);
        next if $tag eq "";

        # 若值中已带该前缀（如 "tag:ai generated"）则不重复补全
        unless ( $tag =~ /^\Q$prefix\E:/i ) {
            $tag = $prefix . ":" . $tag;
        }

        $json_tags_set->{ lc($tag) } = $tag;
    }

    return;
}

#build_json_tag_set($hashjson)
#收集 JSON 中可用于去重的标签：
#  1. 顶层 language / tag 字段（兼容字符串或数组）
#  2. 嵌套 tags 对象（nhentai: tags.tag；e-hentai: tags.other / male / female 等），
#     以子键名作为命名空间前缀
#仅用作“标签是否已存在”的判断依据，绝不直接输出。
sub build_json_tag_set {

    my ($hashjson) = @_;

    my $json_tags_set = {};

    # 顶层字段统一复用 add_tags_to_set：非 HASH 值内部按字符串/数组处理，
    # HASH 值（如 tags 对象）由下方嵌套解析专门处理
    for my $field (qw(language tag)) {
        add_tags_to_set( $json_tags_set, $field, $hashjson->{$field} );
    }

    # 嵌套 tags 对象：以子键名（tag/other/male/female...）作为命名空间前缀
    my $nested_tags = $hashjson->{tags};

    if ( ref $nested_tags eq "HASH" ) {

        for my $namespace ( sort keys %$nested_tags ) {

            my $value = $nested_tags->{$namespace};

            # 值可能是字符串或数组，统一交给 add_tags_to_set 处理
            next unless defined $namespace && length $namespace;
            next if ref $value eq "HASH";

            add_tags_to_set( $json_tags_set, $namespace, $value );
        }
    }

    return $json_tags_set;
}

#json_has_tag($json_tags_set, $target_tag, $case_insensitive)
#判断目标标签是否已存在于 JSON 去重集合中。
#集合键本身已小写化：默认等价于大小写不敏感匹配，
#$case_insensitive 为真时再显式做一次小写精确比对。
sub json_has_tag {

    my ( $json_tags_set, $target_tag, $case_insensitive ) = @_;

    return 0 unless $json_tags_set && %$json_tags_set;

    if ($case_insensitive) {
        my $wanted = lc($target_tag);
        return 1 if exists $json_tags_set->{$wanted};
    }

    return 1 if exists $json_tags_set->{ lc($target_tag) };

    return 0;
}

1;
