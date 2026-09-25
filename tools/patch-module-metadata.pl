#!/usr/bin/env perl
use strict;
use warnings;
use bytes;
use File::Basename qw(dirname);
use File::Copy qw(move);
use File::Temp qw(tempfile);

sub usage {
    die "usage: $0 <Module.symvers> <kernel-vermagic> <llvm-objcopy> <module>...\n";
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "open $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh or die "close $path: $!\n";
    return $data;
}

sub write_file {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "open $path: $!\n";
    print {$fh} $data or die "write $path: $!\n";
    close $fh or die "close $path: $!\n";
}

sub module_versions {
    my ($module) = @_;
    open my $fh, '-|', 'modprobe', '--show-modversions', $module
        or die "run modprobe for $module: $!\n";
    my @versions;
    while (my $line = <$fh>) {
        chomp $line;
        my ($crc, $symbol) = split /\s+/, $line, 2;
        die "invalid module version entry in $module: $line\n"
            unless defined $crc && defined $symbol && $crc =~ /^0x[0-9a-fA-F]+$/;
        push @versions, [$crc, $symbol];
    }
    close $fh or die "modprobe failed for $module\n";
    return @versions;
}

usage() if @ARGV < 4;
my ($symvers, $vermagic, $objcopy, @modules) = @ARGV;

my %crc_by_symbol;
open my $symvers_fh, '<', $symvers or die "open $symvers: $!\n";
while (my $line = <$symvers_fh>) {
    my ($crc, $symbol) = split /\s+/, $line, 3;
    next unless defined $crc && defined $symbol && $crc =~ /^0x[0-9a-fA-F]+$/;
    $crc_by_symbol{$symbol} = hex($crc);
}
close $symvers_fh or die "close $symvers: $!\n";

for my $module (@modules) {
    my @versions = module_versions($module);
    my $mode = (stat($module))[2] & 07777;
    my $data = read_file($module);

    for my $entry (@versions) {
        my ($old_crc, $symbol) = @$entry;
        die "$module: $symbol is not exported by $symvers\n"
            unless exists $crc_by_symbol{$symbol};

        my $needle = pack('Q<', hex($old_crc)) . $symbol . "\0";
        my $offset = index($data, $needle);
        die "$module: cannot locate __versions entry for $symbol\n"
            if $offset < 0;
        die "$module: ambiguous __versions entry for $symbol\n"
            if index($data, $needle, $offset + 1) >= 0;
        substr($data, $offset, 8) = pack('Q<', $crc_by_symbol{$symbol});
    }

    my ($crc_fh, $crc_module) = tempfile('.module-crc.XXXXXX', DIR => dirname($module), UNLINK => 1);
    binmode $crc_fh;
    print {$crc_fh} $data or die "write $crc_module: $!\n";
    close $crc_fh or die "close $crc_module: $!\n";

    my ($modinfo_fh, $modinfo) = tempfile('.module-modinfo.XXXXXX', DIR => dirname($module), UNLINK => 1);
    close $modinfo_fh or die "close $modinfo: $!\n";
    system($objcopy, '--dump-section', ".modinfo=$modinfo", $crc_module) == 0
        or die "$module: failed to extract .modinfo\n";

    my $modinfo_data = read_file($modinfo);
    my $start = index($modinfo_data, 'vermagic=');
    die "$module: .modinfo does not contain vermagic\n" if $start < 0;
    die "$module: .modinfo contains multiple vermagic entries\n"
        if index($modinfo_data, 'vermagic=', $start + 1) >= 0;
    my $end = index($modinfo_data, "\0", $start);
    die "$module: malformed vermagic entry\n" if $end < 0;
    substr($modinfo_data, $start, $end - $start + 1) = "vermagic=$vermagic\0";
    write_file($modinfo, $modinfo_data);

    my ($final_fh, $final_module) = tempfile('.module-final.XXXXXX', SUFFIX => '.ko', DIR => dirname($module), UNLINK => 0);
    close $final_fh or die "close $final_module: $!\n";
    unlink $final_module or die "unlink $final_module: $!\n";
    system($objcopy, '--update-section', ".modinfo=$modinfo", $crc_module, $final_module) == 0
        or die "$module: failed to update .modinfo\n";

    my @patched_versions = module_versions($final_module);
    for my $entry (@patched_versions) {
        my ($crc, $symbol) = @$entry;
        die "$module: patched module lost $symbol\n"
            unless exists $crc_by_symbol{$symbol};
        die "$module: CRC mismatch remains for $symbol\n"
            if hex($crc) != $crc_by_symbol{$symbol};
    }

    open my $vermagic_fh, '-|', 'modinfo', '-F', 'vermagic', $final_module
        or die "run modinfo for $final_module: $!\n";
    my $patched_release = <$vermagic_fh>;
    close $vermagic_fh or die "modinfo failed for $final_module\n";
    chomp $patched_release;
    die "$module: vermagic update failed\n" unless $patched_release eq $vermagic;

    chmod $mode, $final_module or die "chmod $final_module: $!\n";
    move($final_module, $module) or die "replace $module: $!\n";
    print "patched $module: ", scalar(@patched_versions), " symbol CRCs\n";
}
