package LANraragi::Plugin::Metadata::Ezenh;

# ============================================================================
# Ezenh.pm —— eze 风格 info.json 元数据插件
#
# 功能：
#   * 解析 {'gallery_info': {...}} 结构的 info.json，
#     文件可内嵌于压缩包，也可为同级同名的外部 {archive_name}.json；
#   * 标题优先 title_original，兼容 title_title_original 拼写，最后回退 title；
#   * gallery_info.tags 各命名空间展开为 LRR 标签，去重并按固定顺序输出；
#   * upload_date 数组按 UTC 换算为 Unix 时间戳（秒），输出 timestamp:；
#   * source: 直接取顶层 link 字段，不解析 source 对象；
#   * 错误一律以 die "...\n" 抛出。
# ============================================================================

use strict;
use warnings;
use utf8;

#state 用于缓存命名空间排序权重。
use 5.010;

use Mojo::JSON qw(from_json);
use File::Basename;
#timegm_modern 为 Perl 内置模块，用于把 upload_date 按 UTC 换算成 Unix 时间戳。
use Time::Local qw(timegm_modern);

use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging qw(get_plugin_logger);
use LANraragi::Utils::String  qw(trim);
use LANraragi::Utils::Archive qw(is_file_in_archive extract_file_from_archive);
#open_path_or_die 用于打开文件；unlink_path 用于删除解包出的临时文件
#（Windows 长路径下同样可用，故不使用裸 unlink）。
use LANraragi::Utils::Path qw(open_path_or_die unlink_path);

#命名空间的输出顺序。哈希与 JSON 键序都不稳定，必须显式排序才能保证输出可复现。
use constant NAMESPACE_ORDER =>
  qw(category language artist group parody character tag cosplayer upload_date timestamp source);

#插件元信息
sub plugin_info {

    return (
        name        => "Ezenh",
        type        => "metadata",
        namespace   => "ezenh",
        author      => "nuonituan",
        version     => "1.1",
        description =>
          "解析 eze 风格的 info.json 元数据（{'gallery_info': {xxx}} 结构），"
          . "文件可以内嵌在压缩包中，也可以是与压缩包同级同名的外部文件（{archive_name}.json）。"
          . "标题优先使用 title_original（兼容 title_title_original 拼写，缺失或空白时回退 title）；"
          . "upload_date 数组按 UTC 换算为 Unix 时间戳（秒），输出 timestamp: 标签；"
          . "source: 标签直接取顶层 link 字段。",
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

        #命名参数哈希；当前无需用户配置，全部行为均为固定策略。
        parameters => {}
    );

}

#插件必须实现的主函数
sub get_tags {

    shift;

    # $lrr_info: LRR 提供的全局信息哈希
    # $params  : 插件参数（当前无参数，保留形参以符合 LRR 调用约定）
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

    #黄金顺序：先固定 $@，再清理（清理中的文件操作会覆盖 $@），最后 die。
    my $read_error = $@;

    if ($read_error) {
        _safe_log( $logger, 'error', "Failed to read $filepath: $read_error" );
        _delete_temp_file( $filepath, $delete_after_parse );
        die "Failed to read the info.json file!\n";
    }

    # ---- 第三步：解析 JSON ----
    my $hashjson = eval { from_json $stringjson };

    #黄金顺序：先固定 $@，再清理，最后 die。
    my $parse_error = $@;

    if ($parse_error) {
        _safe_log( $logger, 'error', "JSON parsing failed: $parse_error" );
        _delete_temp_file( $filepath, $delete_after_parse );
        die "The info.json file could not be parsed as an eze file!\n";
    }

    _safe_log( $logger, 'debug', "Loaded the following JSON: $stringjson" );

    #gallery_info 必须存在且为对象，否则不是 eze 结构。
    if ( ref $hashjson ne "HASH" || ref $hashjson->{gallery_info} ne "HASH" ) {
        _delete_temp_file( $filepath, $delete_after_parse );
        die "The info.json file could not be parsed as an eze file!\n";
    }

    # ---- 第四步：提取标签与标题 ----
    #用 eval 包裹以便在提取异常时也能走到统一的临时文件清理。
    my ( $tags, $title );

    eval {
        ( $tags, $title ) = _tags_from_eze_json( $hashjson, $logger );
    };

    #黄金顺序：先固定 $@，再清理，最后 die。
    my $extract_error = $@;

    _delete_temp_file( $filepath, $delete_after_parse );

    if ($extract_error) {
        _safe_log( $logger, 'error', "Tag extraction failed: $extract_error" );
        die "Failed to extract tags from info.json!\n";
    }

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

#_tags_from_eze_json($hash, $logger)
#从 gallery_info 提取标签串与标题，返回 (标签串, 标题)。
sub _tags_from_eze_json {

    my ( $hash, $logger ) = @_;

    my $gallery_info = $hash->{gallery_info};

    #upload_date 按 UTC 换算为 Unix 时间戳（秒）。
    my $timestamp = _upload_date_to_epoch( $gallery_info->{upload_date}, $logger );

    my $tags = _build_tags( $gallery_info, $timestamp, $logger );

    my $title = _build_title($gallery_info);

    return ( $tags, $title );
}

#_build_tags($gallery_info, $timestamp, $logger)
#把 tags 对象、category、link 与时间戳拼成逗号分隔的标签串。
sub _build_tags {

    my ( $gallery_info, $timestamp, $logger ) = @_;

    #%seen 以完整标签去重；%collected 先归类，最后统一排序输出。
    my %collected;
    my %seen;

    my $tags = $gallery_info->{tags};

    #tags 缺失或非对象时视为「没有标签」，仍继续输出时间戳 / category / source。
    if ( ref $tags eq "HASH" ) {

        foreach my $namespace ( keys %$tags ) {

            next if ref $namespace;    # 命名空间名必须是普通字符串
            next if $namespace eq "";

            my $members = $tags->{$namespace};

            #值通常是数组；个别导出工具会写成单个字符串，统一处理。
            my @members = ref $members eq "ARRAY" ? @$members : ( ref $members ? () : ($members) );

            foreach my $member (@members) {

                next unless defined $member;
                next if ref $member;

                my $tag = trim($member);
                next if $tag eq "";

                _push_tag( \%collected, \%seen, $namespace, $tag );
            }
        }
    } else {
        _safe_log( $logger, 'warn', "No 'tags' object found in gallery_info, only the extra tags will be returned." );
    }

    #必须用 defined 判断：1970-01-01 的时间戳为 0，改为真值判断会误杀该合法值。
    if ( defined $timestamp ) {
        _push_tag( \%collected, \%seen, "timestamp", $timestamp );
    }

    #顶层 category 字段（doujinshi / manga 等）；与 tags 中的同名标签自动去重。
    my $category = _get_scalar_string( $gallery_info->{category} );

    if ( $category ne "" ) {
        _push_tag( \%collected, \%seen, "category", $category );
    }

    #source: 直接取顶层 link；缺失时不出该标签。
    my $link = _get_scalar_string( $gallery_info->{link} );

    if ( $link ne "" ) {
        _push_tag( \%collected, \%seen, "source", $link );
    } else {
        _safe_log( $logger, 'debug', "No 'link' field found in gallery_info, skipping the source tag." );
    }

    my $return = "";

    foreach my $namespace ( sort _compare_ns keys %collected ) {

        foreach my $tag ( sort keys %{ $collected{$namespace} } ) {

            $return .= ", " unless $return eq "";
            $return .= $namespace . ":" . $tag;
        }
    }

    return $return;
}

#_push_tag(\%collected, \%seen, $namespace, $tag)
#按命名空间归类并去重；去重以完整标签 namespace:tag 为单位。
sub _push_tag {

    my ( $collected, $seen, $namespace, $tag ) = @_;

    my $full = $namespace . ":" . $tag;

    return if $seen->{$full};

    $seen->{$full}                   = 1;
    $collected->{$namespace}->{$tag} = 1;

    return;
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

#_build_title($gallery_info)
#标题优先级：title_original -> title_title_original（拼写兼容）-> title。
#空白串视为无值，逐级回退。
sub _build_title {

    my ($gallery_info) = @_;

    my $title = trim( _get_scalar_string( $gallery_info->{title} ) );

    my $title_original = trim( _get_scalar_string( $gallery_info->{title_original} ) );

    return $title_original if $title_original ne "";

    my $title_typo = trim( _get_scalar_string( $gallery_info->{title_title_original} ) );

    return $title_typo if $title_typo ne "";

    return $title;
}

#_upload_date_to_epoch($date_arr, $logger)
#把 upload_date 数组 [YYYY, M, D, H, M, S] 按 UTC 换算成 Unix 时间戳（秒）。
#时区固定为 UTC，保证同一份元数据在任何时区得到相同结果。
#返回 undef 表示该字段不可用，调用方跳过 timestamp 标签，不视为错误。
sub _upload_date_to_epoch {

    my ( $date_arr, $logger ) = @_;

    #年月日不全则跳过；时分秒允许缺省（补 0）。
    return unless ref $date_arr eq 'ARRAY' && @$date_arr >= 3;

    return unless _is_numeric( $date_arr->[0] )
      && _is_numeric( $date_arr->[1] )
      && _is_numeric( $date_arr->[2] );

    my ( $year, $month, $day ) = map { int( $date_arr->[$_] ) } 0 .. 2;
    my $hour   = @$date_arr >= 4 ? int( $date_arr->[3] ) : 0;
    my $minute = @$date_arr >= 5 ? int( $date_arr->[4] ) : 0;
    my $second = @$date_arr >= 6 ? int( $date_arr->[5] ) : 0;

    #范围检查：月份 1-12（JSON 为 1-based）、日 1-31、时分秒各自的范围。
    return unless $month >= 1 && $month <= 12 && $day >= 1 && $day <= 31;
    return unless $hour >= 0 && $hour <= 23 && $minute >= 0 && $minute <= 59 && $second >= 0 && $second <= 60;

    #timegm_modern 的月份是 0-based，需减 1；越界日期会抛异常，用 eval 接住并跳过。
    my $epoch = eval { timegm_modern( $second, $minute, $hour, $day, $month - 1, $year ) };

    if ( !defined $epoch ) {
        _safe_log( $logger, 'warn', "Invalid 'upload_date' value, skipping the timestamp tag." );
        return;
    }

    #往返校验：把结果按 UTC 还原回日期，必须与原值完全一致。
    #timegm_modern 会把「2 月 31 日」这类不存在的日期静默进位到 3 月，
    #此校验用于拦截这种进位，避免输出与 JSON 声明不符的时间戳。
    my ( undef, undef, undef, $rt_day, $rt_month, $rt_year ) = gmtime($epoch);

    if ( $rt_day != $day || ( $rt_month + 1 ) != $month || ( $rt_year + 1900 ) != $year ) {
        _safe_log( $logger, 'warn', "Non-existent 'upload_date' date, skipping the timestamp tag." );
        return;
    }

    #返回数值本身：0 是合法时间戳，调用方以 defined 而非真值判断。
    return $epoch;
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
#判断是否为可直接参与算术/时间换算的数字值。
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
