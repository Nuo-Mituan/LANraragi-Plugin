package LANraragi::Plugin::Metadata::EHjson;

# ============================================================================
# EHjson.pm —— 扁平结构 e-hentai JSON 元数据插件
#
# 功能：
#   * 解析扁平结构的 JSON（tags / title 等字段直接位于顶层），
#     文件可内嵌于压缩包，也可为同级同名的外部 {archive_name}.json；
#   * 顶层 tags 各命名空间展开为 LRR 标签，去重并按固定顺序输出；
#   * male / female / mixed / other 四个命名空间统一合并为 tag:；
#   * posted 字段（Unix 时间戳，秒）直接输出 timestamp:，不做日期换算；
#   * category: 取顶层 category，source: 取顶层 url；
#   * 标题默认 title，use_jpn_title 启用且存在 title_jpn 时优先后者；
#   * 错误一律以 die "...\n" 抛出。
# ============================================================================

use strict;
use warnings;
use utf8;

#state 用于缓存命名空间排序权重。
use 5.010;

use Mojo::JSON qw(from_json);
use File::Basename;

use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging qw(get_plugin_logger);
use LANraragi::Utils::String  qw(trim);
use LANraragi::Utils::Archive qw(is_file_in_archive extract_file_from_archive);
#open_path_or_die 用于打开文件；unlink_path 用于删除解包出的临时文件
#（Windows 长路径下同样可用，故不使用裸 unlink）。
use LANraragi::Utils::Path qw(open_path_or_die unlink_path);

#需要合并到 tag: 的命名空间：E-Hentai 中属于「男性 / 女性 / 混合 / 其他」分类，
#在 LRR 标签规则中统一归入通用的 tag: 命名空间。
use constant MERGED_NAMESPACES => qw(male female mixed other);

#命名空间的输出顺序。哈希与 JSON 键序都不稳定，必须显式排序才能保证输出可复现。
#注意：male / female / mixed / other 已合并为 tag，故此处只列 tag，
#若仍列原名会使合并结果取不到权重而被排到末尾。
use constant NAMESPACE_ORDER =>
  qw(language artist group parody character tag cosplayer temp timestamp category source);

#插件元信息
sub plugin_info {

    return (
        name        => "E-Hjson",
        type        => "metadata",
        namespace   => "ehjson",
        author      => "nuomituan",
        version     => "1.1",
        description =>
          "解析扁平结构的 e-hentai JSON 元数据（压缩包内嵌 info.json 或同级同名外部文件 {archive_name}.json）。"
          . "标签直接取自 JSON 顶层的 tags 对象并将其中的 male / female / mixed / other 统一合并为 tag: 命名空间；"
          . "posted 字段（Unix 时间戳，秒）映射为 timestamp: 标签，另附带 category: 与 source: 标签。",
        icon =>
          "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAACXBIWXMAAAsTAAALEwEAmpwYAAAA\n"
          . "B3RJTUUH4wYCFDYBnHlU6AAAAB1pVFh0Q29tbWVudAAAAAAAQ3JlYXRlZCB3aXRoIEdJTVBkLmUH\n"
          . "AAAETUlEQVQ4y22UTWhTWRTHf/d9JHmNJLFpShMcKoRIqxXE4sKpjgthYLCLggU/wI1CUWRUxlmU\n"
          . "Wblw20WZMlJc1yKKKCjCdDdYuqgRiygq2mL8aJpmQot5uabv3XdnUftG0bu593AOv3M45/yvGBgY\n"
          . "4OrVqwRBgG3bGIaBbduhDSClxPM8tNZMTEwwMTGB53lYloXWmkgkwqdPnygUCljZbJbW1lYqlQqG\n"
          . "YYRBjuNw9+5dHj16RD6fJ51O09bWxt69e5mammJ5eZm1tTXi8Tiu6xKNRrlx4wZWNBqlXq8Tj8cx\n"
          . "TRMhBJZlMT4+zuXLlxFCEIvFqFarBEFAKpXCcRzq9TrpdJparcbIyAiHDh1icXERyzAMhBB4nofv\n"
          . "+5imiWmavHr1inQ6jeM4ZLNZDMMglUqxuLiIlBLXdfn48SNKKXp6eqhUKiQSCaxkMsna2hqe52Hb\n"
          . "NsMdec3n8+Pn2+vpETt37qSlpYVyucz8/DzT09Ns3bqVYrEIgOM4RCIRrI1MiUQCz/P43vE8jxcv\n"
          . "XqCUwvM8Zmdn2bJlC6lUitHRUdrb2zFNE9/3sd6/f4/jOLiuSzKZDCH1wV/EzMwM3d3dNN69o729\n"
          . "nXK5jFKKPXv2sLS0RF9fHydOnMD3fZRSaK0xtNYEQYBpmtTr9RC4b98+LMsCwLZtHj9+TCwWI5/P\n"
          . "I6Xk5MmTXLhwAaUUG3MA4M6dOzQaDd68eYOUkqHIZj0U2ay11mzfvp1du3YhhGBgYIDjx4/T3d1N\n"
          . "vV4nCAKklCilcF2XZrOJlBIBcOnSJc6ePYsQgj9yBf1l//7OJcXPH1Y1wK/Ff8SfvT995R9d/SA8\n"
          . "zyMaja5Xq7Xm1q1bLCwssLS09M1Atm3bFr67urq+8W8oRUqJlBJLCMHNmze5d+8e2Ww2DPyrsSxq\n"
          . "tRqZTAattZibm6PZbHJFVoUQgtOxtAbwfR8A13WJxWIYANVqFd/36e/v/ypzIpEgCAKEEMzNzYXN\n"
          . "34CN/FsSvu+jtSaTyeC67jrw4cOHdHZ2kslkQmCz2SQSiYT269evMU0zhF2RVaH1ejt932dlZYXh\n"
          . "4eF14MLCArZtI6UMAb+1/qBPx9L6jNOmAY4dO/b/agBnnDb9e1un3vhQzp8/z/Xr19eBQgjevn3L\n"
          . "1NTUd5WilKJQKGAYxje+lpYWrl27xuTk5PqKARSLRfr6+hgaGiKbzfLy5UvGx8dRSqGUwnEcDMNA\n"
          . "KYUQIlRGNBplZmaGw4cPE4/HOXDgAMbs7Cy9vb1cvHiR+fl5Hjx4QC6XwzAMYrEYz549Y3p6mufP\n"
          . "n4d6NU0Tx3GYnJzk6NGjNJtNduzYQUdHB+LL8mu1Gv39/WitGRsb4/79+3R1dbF793/s3XvI5XK5\n"
          . "cPqNRoNTp05x5MgRxsbG8H2fgwcPkk6nMTdg5XKZTCZDqVQC4Ny5c5RKJSqVSjx9+pREIsGmTZtY\n"
          . "WVnhyZMnDA4OorXm9u3b7N+/n3w+z+rqKv/pWwNY8k3GIwAAAABJRU5ErkJggg==",

        #命名参数哈希：控制标题来源。
        parameters => {
            'use_jpn_title' => {
                type          => "bool",
                desc          => "优先使用 title_jpn（日文标题）作为归档标题；关闭时使用 title 字段",
                default_value => "false"
            }
        }
    );

}

#插件必须实现的主函数
sub get_tags {

    shift;

    # $lrr_info: LRR 提供的全局信息哈希
    # $params  : 插件参数哈希（命名参数格式）
    my ( $lrr_info, $params ) = @_;

    $params //= {};

    my $logger = get_plugin_logger();

    # ---- 第一步：定位 JSON 文件 ----
    #优先压缩包内嵌的 info.json，其次同级同名的外部 {archive_name}.json。
    my ( $filepath, $delete_after_parse ) = _find_metadata_json( $lrr_info->{file_path}, $logger );

    if ( !$filepath ) {
        die "No in-archive info.json or {archive_name}.json file found!\n";
    }

    # ---- 第二步：读取文件内容 ----
    #读取失败（权限、编码、I/O 中断）必须纳入 eval，否则崩溃会跳过后续清理，
    #令解包出的临时文件残留在磁盘上。
    my $stringjson = "";

    eval {
        #必须直传 $fh 以利用 @_ 别名机制绑定句柄（改传 \$fh 会因收到引用而失败）。
        my $fh;
        open_path_or_die( $fh, '<:encoding(UTF-8)', $filepath );

        while ( my $row = <$fh> ) {
            chomp $row;
            $stringjson .= $row;
        }

        close $fh;
        1;
    };

    #先固定 $@：后续的日志与清理都会覆盖它，之后才能安全地报错。
    my $read_error = $@;

    if ($read_error) {
        _safe_log( $logger, 'error', "Failed to read $filepath: $read_error" );
        _delete_temp_file( $filepath, $delete_after_parse );
        die "Failed to read the JSON file: $filepath\n";
    }

    # ---- 第三步：解析 JSON ----
    my $hashjson = eval { from_json $stringjson };

    my $parse_error = $@;

    if ($parse_error) {
        _safe_log( $logger, 'error', "JSON parsing failed: $parse_error" );
        _delete_temp_file( $filepath, $delete_after_parse );
        die "The JSON file could not be parsed: $filepath\n";
    }

    _safe_log( $logger, 'debug', "Loaded the following JSON: $stringjson" );

    #目标 JSON 为扁平结构，顶层必须是对象。
    if ( ref $hashjson ne "HASH" ) {
        _delete_temp_file( $filepath, $delete_after_parse );
        die "The JSON file does not contain a top-level object!\n";
    }

    #eze 等格式会把内容包在 gallery_info 里，本插件按扁平结构解析，
    #与其静默返回空标签，不如明确报错以便改用对应插件。
    if ( exists $hashjson->{gallery_info} ) {
        _delete_temp_file( $filepath, $delete_after_parse );
        die "This JSON looks like an eze-style file (nested 'gallery_info'), use the eze plugin instead!\n";
    }

    # ---- 第四步：提取标签与标题 ----
    #用 eval 包裹以便在提取异常时也能走到统一的临时文件清理。
    my ( @taglist, $title );

    eval {
        @taglist = _build_tags( $hashjson, $logger );
        $title   = _build_title( $hashjson, $params->{use_jpn_title} );
        1;
    };

    my $build_error = $@;

    if ($build_error) {
        _safe_log( $logger, 'error', "Failed to extract metadata from $filepath: $build_error" );
        _delete_temp_file( $filepath, $delete_after_parse );

        #具体原因已在日志中，此处只给使用者一句可读的提示。
        die "Failed to extract metadata from the JSON file!\n";
    }

    _delete_temp_file( $filepath, $delete_after_parse );

    #标签按 LRR 约定以逗号分隔
    my $tags = join( ', ', @taglist );

    _safe_log( $logger, 'info', "Sending the following tags to LRR: $tags" );

    if ($title) {
        _safe_log( $logger, 'info', "Parsed title is $title" );
        return ( tags => $tags, title => $title );
    }

    return ( tags => $tags );
}

#_find_metadata_json($file_path, $logger)
#按固定顺序查找元数据 JSON 文件：先压缩包内嵌 info.json，再次同级同名外部文件。
#返回列表 (文件路径, 是否需要删除临时文件)；均未找到时返回空列表。
sub _find_metadata_json {

    my ( $file_path, $logger ) = @_;

    return unless defined $file_path && length $file_path;

    #is_file_in_archive 在文件存在时返回其在包内的确切路径，不存在时返回 undef。
    my $path_in_archive = is_file_in_archive( $file_path, "info.json" );

    if ($path_in_archive) {

        my $extracted = extract_file_from_archive( $file_path, $path_in_archive );

        if ( $extracted && -e $extracted ) {
            _safe_log( $logger, 'debug', "Found file in archive at $extracted" );
            return ( $extracted, 1 );
        }

        _safe_log( $logger, 'warn', "Failed to extract in-archive info.json: $path_in_archive" );
    }

    #直接使用 fileparse 的 $dir 拼接路径（$dir 自带结尾分隔符），
    #避免 create_path 在 Windows 下返回 Path 对象带来的副作用。
    my ( $name, $dir ) = fileparse( $file_path, qr/\.[^.]*/ );
    my $path_nearby_json = $dir . $name . '.json';

    if ( -e $path_nearby_json ) {
        _safe_log( $logger, 'debug', "Found file nearby at $path_nearby_json" );

        #同级同名文件属于使用者自己的文件，不得删除。
        return ( $path_nearby_json, 0 );
    }

    return;
}

#_build_tags($hashjson, $logger)
#把顶层 tags 对象、posted、category、url 拼成标签列表，返回标签数组。
sub _build_tags {

    my ( $hashjson, $logger ) = @_;

    my $tags = $hashjson->{tags};

    #tags 缺失或非对象时视为「没有标签」，仍继续输出 timestamp / category / source。
    if ( ref $tags ne "HASH" ) {
        _safe_log( $logger, 'warn', "No 'tags' object found in the JSON file, tags will be empty." );
        $tags = {};
    }

    my @taglist = _merge_tags($tags);

    #posted 本身就是 Unix 时间戳（秒），只做校验与规整，不做日期换算。
    my $timestamp = _unix_timestamp( $hashjson->{posted} );

    #必须用 defined 判断：时间戳 0 是合法值，真值判断会误杀。
    if ( defined $timestamp ) {
        push @taglist, "timestamp:" . $timestamp;
        _safe_log( $logger, 'debug', "Mapped 'posted' timestamp to timestamp:$timestamp" );
    }

    #顶层 category（Manga / Doujinshi 等）。
    my $category = _get_scalar_string( $hashjson->{category} );

    if ( $category ne "" ) {
        push @taglist, "category:" . $category;
    }

    #source: 直接取顶层 url；缺失时不出该标签。
    my $url = _get_scalar_string( $hashjson->{url} );

    if ( $url ne "" ) {
        push @taglist, "source:" . $url;
    }

    return @taglist;
}

#_merge_tags($tags)
#遍历顶层 tags 的各命名空间，把 male / female / mixed / other 合并为 tag:，
#其余命名空间原样保留；同一命名空间内去重，最后按固定顺序输出。
#返回标签数组。
sub _merge_tags {

    my ($tags) = @_;

    my %merged = map { $_ => 1 } MERGED_NAMESPACES;

    my %collected;    # 命名空间 => { 标签 => 1 }，利用哈希键唯一性去重

    foreach my $namespace ( keys %$tags ) {

        my $members = $tags->{$namespace};

        #值通常是数组；个别导出工具会写成单个字符串，统一处理。
        my @members = ref $members eq "ARRAY" ? @$members : ( ref $members ? () : ($members) );

        #合并规则：这四种命名空间下的标签一律改挂到 tag: 下。
        my $target_ns = $merged{$namespace} ? "tag" : $namespace;

        foreach my $member (@members) {

            next unless defined $member;
            next if ref $member;

            my $tag = trim($member);
            next if $tag eq "";

            #仅移除 "namespace:xxx" 形式的前缀，避免误伤 tagged 这类本身含命名空间名的标签；
            #冒号后要求至少一个字符，故 "tag:" 不会被截断成空串。
            if ( $tag =~ /^\Q$target_ns\E:(.+)$/i ) {
                $tag = $1;
            }

            $collected{$target_ns}->{$tag} = 1;
        }
    }

    my @taglist;

    foreach my $namespace ( sort _compare_ns keys %collected ) {

        foreach my $tag ( sort keys %{ $collected{$namespace} } ) {
            push @taglist, $namespace . ":" . $tag;
        }
    }

    return @taglist;
}

#_build_ns_rank_ref()
#把 NAMESPACE_ORDER 转换成「命名空间 => 序号」的哈希引用。
sub _build_ns_rank_ref {

    my %rank;
    my $index = 0;

    $rank{$_} = $index++ foreach NAMESPACE_ORDER;

    return \%rank;
}

#_compare_ns($a, $b)
#sort 辅助：按 NAMESPACE_ORDER 排序，未列出的命名空间排最后并按字典序。
sub _compare_ns {

    #state 保证权重只构建一次，且作用域限于本函数。
    state $rank = _build_ns_rank_ref();

    my $unknown = scalar NAMESPACE_ORDER;

    my $rank_a = exists $rank->{$a} ? $rank->{$a} : $unknown;
    my $rank_b = exists $rank->{$b} ? $rank->{$b} : $unknown;

    return $rank_a <=> $rank_b if $rank_a != $rank_b;

    return $a cmp $b;
}

#_build_title($hashjson, $use_jpn_title)
#标题默认取 title；use_jpn_title 启用且 title_jpn 非空白时优先 title_jpn。
sub _build_title {

    my ( $hashjson, $use_jpn_title ) = @_;

    #LRR 的 bool 参数为勾选框：勾选存 "1"、未勾选存空串、从未保存则无该键，
    #三种情况按 Perl 真值判断均为正确结果。
    my $title     = trim( _get_scalar_string( $hashjson->{title} ) );
    my $title_jpn = trim( _get_scalar_string( $hashjson->{title_jpn} ) );

    if ( $use_jpn_title && $title_jpn ne "" ) {
        return $title_jpn;
    }

    return $title;
}

#_unix_timestamp($posted)
#校验并规整 posted 的 Unix 时间戳（秒）；缺失、非数字或负数返回 undef，
#调用方据此跳过 timestamp 标签，不视为错误。
sub _unix_timestamp {

    my ($posted) = @_;

    return unless _is_numeric($posted);

    #Unix 时间戳不应为负数。
    my $timestamp = int($posted);
    return if $timestamp < 0;

    return $timestamp;
}

#_get_scalar_string($value)
#安全取值：undef 或非标量（数组 / 对象）一律返回空串，避免把引用拼进标签串。
sub _get_scalar_string {

    my ($value) = @_;

    return "" unless defined $value;
    return "" if ref $value;

    return $value;
}

#_is_numeric($value)
#判断是否为可直接参与算术运算的数字值。
sub _is_numeric {

    my ($value) = @_;

    return 0 unless defined $value;
    return 0 if ref $value;

    return $value =~ /^\s*[+-]?\d+(?:\.\d+)?\s*$/ ? 1 : 0;
}

#_safe_log($logger, $level, $message)
#日志隔离：日志后端可能因磁盘满、文件占用、加锁失败等抛异常。
#日志只是旁路信息，若其异常打断主流程，紧随其后的 die 会被跳过，
#LRR 前端收到的将是日志崩溃信息而非真正的解析错误。
#因此用 eval 吞掉日志异常，保证主流程与错误上报不受影响。
sub _safe_log {

    my ( $logger, $level, $message ) = @_;

    return unless $logger;

    #白名单级别，避免把任意方法名交给 $logger->$level 动态调用。
    return unless defined $level && $level =~ /^(?:debug|info|warn|error)$/;

    eval { $logger->$level($message); };

    #故意不处理 $@：日志失败可忽略，绝不能中断主流程。
    return;
}

#_delete_temp_file($filepath, $delete_after_parse)
#删除解包出的临时文件；$delete_after_parse 为假（同级同名外部文件）时不删。
sub _delete_temp_file {

    my ( $filepath, $delete_after_parse ) = @_;

    return unless $delete_after_parse;
    return unless defined $filepath && -e $filepath;

    unlink_path($filepath);

    return;
}

1;
