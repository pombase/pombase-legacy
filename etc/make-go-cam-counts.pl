#!/usr/bin/env perl

# read the GO-CAM mapping files from the release directory and make tables
# for plotting date vs gene count and date vs model count

use strict;
use warnings;
use Carp;

my $date_genes_filename = shift;
my $date_models_filename = shift;

my $releases_dir = '/var/www/pombase/dumps/releases';

my @mapping_files = ();

opendir(my $dh, $releases_dir) || die "Can't open $releases_dir: $!";
while (defined (my $ent = readdir $dh)) {
  if ($ent =~ /^pombase-((\d\d\d\d)-\d\d-\d\d)/ && $2 >= 2024) {
    my $date = $1;
    my $mapping_file = "$releases_dir/$ent/pombe-embl/supporting_files/production_gocam_id_mapping.tsv";
    if (-f $mapping_file) {
      push @mapping_files, [$date, $mapping_file];
    }
  }
}
closedir $dh;


open my $date_genes_file, '>', $date_genes_filename
  || die "Can't open $date_genes_filename for writing: $!\n";
open my $date_models_file, '>', $date_models_filename
  || die "Can't open $date_models_filename for writing: $!\n";

print $date_genes_file "date,genes\n";
print $date_genes_file "2024-04-01,0\n";

print $date_models_file "date,models\n";
print $date_models_file "2024-04-01,0\n";

@mapping_files = sort { $a->[0] cmp $b->[0] } @mapping_files;

for my $date_and_file (@mapping_files) {
  my $date = $date_and_file->[0];
  my $file = $date_and_file->[1];
  my %genes = ();
  my %models = ();
  open my $fh, '<', $file || die "Can't open $file: $!\n";
  while (defined (my $line = <$fh>)) {
    next if $line =~ /^#/;
    chomp $line;
    my ($gene, $model) = split /\t/, $line;

    $genes{$gene} = 1;
    $models{$model} = 1;
  }
  close $fh;

  print $date_genes_file "$date,", (scalar keys %genes), "\n";
  print $date_models_file "$date,", (scalar keys %models), "\n";
}

close $date_models_file;
close $date_genes_file;
