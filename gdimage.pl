#!/usr/bin/perl

use strict;
use Encode;
use FindBin qw/$Bin/;
use CGI qw/:standard escapeHTML/;
use CGI::Carp qw/fatalsToBrowser set_message/;
use HTML::Template;
use GD;

my $config = "$Bin/../etc/gdimage.conf";
my $cgi    = CGI->new;
my ( %config, %params, $errors );

read_config();
upload_img() if $cgi->param;
create_page();

exit;

sub read_config {
    open ( CONF, "< $config") || die "Error open file $config.";

    while( <CONF> ) {
        chomp;
        s/#.*//;
        s/^\s+//;
        s/\s+$//;

        next unless length;

        my ( $var, $value ) = split( /\s*=\s*/, $_, 2 );
        $config{$var} = $value;
    }

    close( CONF );
}

sub upload_img {
    my @chars     = (0..9);
    my $erdiv     = sub { div( $_[0] ) };
    my %fields    = (
        width   => { name => 'Ширина',   regexp => qr/^\d+$/, min => 10, max => 1000 },
        heigth  => { name => 'Высота',   regexp => qr/^\d+$/, min => 10, max => 1000 },
        quality => { name => 'Качество', regexp => qr/^\d+$/, min => 10, max => 100  },
    );
    my (
        $file,                          # то что получили из формы
        $info,                          # структра с информацией о файле
        $size,                          # размер файла
        $type,                          # тип файла
        $data,                          # бинарные данные фото
        $download_file,                 # имя файлы для скачивания
        $download_url,                  # url файлы для скачивания
        $img_orig,                      # GD объект оригинального фото
        $width_orig, $height_orig,      # размеры оригинального фото
        $img_new,                       # GD объект нового фото
        $width_new, $height_new,        # размеры нового фото
    );

    $file              = $cgi->param('img')       || '';
    $params{watermark} = $cgi->param('watermark') || '';

    $errors .= $erdiv->('Ошибка! Не выбран загружаемый файл.') unless $file;

    foreach ( keys %fields ) {
        SWITCH: {
            my $value = $cgi->param($_) || '';
            my $param = $fields{$_};

            if( /^quality$/ && ! $value ) {
                $errors .= $erdiv->( sprintf( 'Ошибка! Не задано значение поля %s.', $param->{name} ) );
                last SWITCH;
            }
            elsif( /^(?:width|heigth)$/ && ! $value ) {
                last SWITCH;
            }

            unless( $value =~ /$param->{regexp}/ ) {
                $errors .= $erdiv->( sprintf( 'Ошибка! В значении поля %s = \'%s\'.', $param->{name}, $value ) );
                last SWITCH;
            }

            if( exists $param->{min} && $param->{min} > $value ) {
                $errors .= $erdiv->( sprintf(
                    'Ошибка! В значении поля %s = \'%s\'. Значение не может быть меньше \'%s\'',
                    $param->{name}, $value, $param->{min}
                ) );
                last SWITCH;
            }

            if( exists $param->{max} && $param->{max} < $value ) {
                $errors .= $erdiv->( sprintf (
                    'Ошибка! В значении поля %s = \'%s\'. Значение не может быть больше \'%s\'',
                    $param->{name}, $value, $param->{max}
                ) );
                last SWITCH;
            }

            $params{$_} = $value;
        }
    }

    $errors .= $erdiv->('Ошибка! Одно из полей ширина или высота, должно быть определено.')
        unless( exists $params{width} || exists $params{heigth} );

    return '' if $errors;

    $info = $cgi->uploadInfo( $file );
    unless(  ( $type ) = $info->{'Content-Type'} =~ /^image\/(jpeg|png|pjpeg|x-png)/ ) {
        $errors .= $erdiv->('Для загрузки доступны следующие форматы файлов jpeg, png');
        return '';
    }

    $size = ( stat ($file) )[7];
    if( sysread( $file, $data, $size ) != $size ) {
        $errors .= $erdiv->('Размер загруженного файла не соответствует размеру файла загружаемого. Попробуйте загрузить файл еще раз');
        return '';
    }

    # правильный конструктор в соответствии с типом файла
    if( $type =~ /^(?:jpeg|pjpeg)$/ ) {
        $img_orig  = GD::Image->newFromJpegData( $data, 1 );
    }
    elsif( $type =~ /^(?:png|x-png)$/ ) {
        $img_orig  = GD::Image->newFromPngData( $data, 1 );
    }

    # имя файла
    do {
        my $text  = join("", @chars[ map{ rand @chars }(1..8) ]);
        my $time  = sprintf( '%04d%02d%02d%02d%02d%02d',
            sub {( $_[5] + 1900, $_[4] + 1, $_[3], $_[2], $_[1], $_[0] )}->(localtime)
        );

        $download_file = sprintf('%s/%s%s.jpg', $config{download_dir}, $time, $text);
        $download_url  = sprintf('%s/%s%s.jpg', $config{download_url}, $time, $text);
    } while -f $download_file;

    # расчет размеров
    ( $width_orig, $height_orig ) = $img_orig->getBounds();
    if( exists $params{width} && ! exists $params{heigth} ) {
        $width_new  = $params{width};
        $height_new = $height_orig / ( $width_orig / $width_new );
    }
    elsif( exists $params{heigth} && ! exists $params{width} ) {
        $height_new = $params{heigth};
        $width_new  = $width_orig / ( $height_orig / $height_new );
    }
    else {
        $width_new  = $params{width};
        $height_new = $params{heigth};
    }

    # новое фото
    $img_new = GD::Image->newTrueColor( $width_new, $height_new );
    $img_new->copyResized( $img_orig, 0, 0, 0, 0, $width_new, $height_new, $width_orig, $height_orig );

    if( $params{watermark} ) {
        my @bounds    = GD::Image->stringFT( 'FFF', $config{watermark_font}, 15, 0, 10, 20, $params{watermark} );
        my $width     = @bounds[2] + 10;
        my $height    = 30;
        my $watermark = GD::Image->newTrueColor( $width, $height );
        my $white     = $watermark->colorAllocate(255,255,255);
        my $black     = $watermark->colorAllocate(0,0,0);

        $watermark->saveAlpha( 1 );
        $watermark->fill( 1, 1, $watermark->colorAllocateAlpha( 255, 255, 255, 127 ) );
        $watermark->transparent( $black );
        $watermark->stringFT( $white, $config{watermark_font}, 15, 0, 10, 20, $params{watermark} );

        $img_new->copy( $watermark, $width_new - $width, $height_new - $height, 0, 0, $width, $height );
    }

    open ( IMG, "> $download_file") || die 'Error open file.';
    binmode IMG;
    print IMG $img_new->jpeg( $params{quality} );
    close IMG;

    $params{img} = $download_url;
}

sub create_page {
    my $template = HTML::Template->new(
        filename => "$config{template_dir}/index.html",
        path     => [ $config{template} ],
    );

    $template->param(
        width     => exists $params{width}     ? $params{width}     : '',
        heigth    => exists $params{heigth}    ? $params{heigth}    : '',
        quality   => exists $params{quality}   ? $params{quality}   : $config{default_quality},
        watermark => exists $params{watermark} ? $params{watermark} : '',
        img       => exists $params{img} ? $params{img} : '',
        errors    => $errors,
    );

    print $cgi->header(
        -type          => 'text/html',
        -charset       => 'utf-8',
        -Cache_Control => 'no-cache',
    ),
    $template->output;
}
