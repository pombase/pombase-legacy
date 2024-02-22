#!/usr/bin/perl -w

use strict;
use warnings;
use Carp;

use open ':encoding(utf8)';
binmode(STDOUT, 'encoding(UTF-8)');

use Bio::SeqIO;
use Bio::Chado::Schema;
use Memoize;
use Getopt::Long;
use YAML qw(LoadFile);
use POSIX;

BEGIN {
  push @INC, 'lib';
};

use PomBase::Chado;
use PomBase::Chado::LoadFile;
use PomBase::Chado::QualifierLoad;
use PomBase::Chado::CheckLoad;
use PomBase::Chado::IdCounter;
use PomBase::Chado::ExtensionProcessor;
use PomBase::Chado::ParalogProcessor;
use PomBase::Chado::GeneExQualifiersUtil;
use PomBase::Chado::LoadUniProtMapping;
use PomBase::Chado::GenotypeCache;
use PomBase::Config;
use PomBase::Role::OrganismFinder;

my $verbose = 0;
my $quiet = 0;
my $dry_run = 0;
my $test = 0;
my $taxonid = undef;
my @obsolete_term_mapping_files = ();
my $gene_ex_qualifiers;
my @mappings = ();

sub usage {
  die "$0 [-v] [-d] <embl_file> ...\n";
}

if (!GetOptions("verbose|v" => \$verbose,
                "dry-run|d" => \$dry_run,
                "quiet|q" => \$quiet,
                "test|t" => \$test,
                "taxonid=s" => \$taxonid,
                "obsolete-term-map=s" => \@obsolete_term_mapping_files,
                "gene-ex-qualifiers=s" => \$gene_ex_qualifiers,
                "mapping|m=s" => \@mappings)) {
  usage();
}

my $config_file = shift;
my $date_version = shift;
my $host = shift;
my $database = shift;
my $user = shift;
my $password = shift;

my $config = PomBase::Config->new(file_name => $config_file);

my $chado = PomBase::Chado::db_connect($host, $database, $user, $password);

my $gene_ex_qualifier_util = PomBase::Chado::GeneExQualifiersUtil->new();

my $guard = $chado->txn_scope_guard;

# load extra CVs, cvterms and dbxrefs
print "loading genes into $database ...\n" unless $quiet;

sub read_mapping {
  my $old_name = shift;
  my $file_name = shift;

  my %ret = ();

  open my $file, '<', $file_name or die "$!: $file_name\n";

  while (defined (my $line = <$file>)) {
    chomp;

    if ($line =~ /$old_name,\s*(.*?)\s+(\S+)$/) {
      $ret{$1} = $2;
    } else {
      if ($line =~ /\s*(.*?)\s+(\S+)$/) {
        $ret{$1} = $2;
      } else {
        warn "unknown format for line from mapping file: $line";
      }
    }
  }

  return \%ret;
}

sub process_mappings {
  my @mappings = @_;

  return map {
    my @parts = split /:/, $_, 4;
    if (@parts >= 3) {
      ($parts[0], { new_name => $parts[1], mapping => read_mapping($parts[0], $parts[2]), db_xref => $parts[3] });
    } else {
      warn "unknown mapping: $_\n";
      usage();
    }
  } @mappings;
}

$config->{test_mode} = $test;
$config->{mappings} = {process_mappings(@mappings)};

sub read_obsolete_term_mapping {
  my $file_name = shift;

  my %ret = ();

  open my $file, '<', $file_name or die "$!: $file_name\n";

  while (defined (my $line = <$file>)) {
    chomp $line;

    next if $line =~ /^!/;
    my @bits = split /\t/, $line;
    $ret{$bits[1]} = $bits[0];
  }

  close $file;

  return %ret;
}

sub process_obsolete_term_mapping_files {
  my @obsolete_term_files = @_;

  return (map { read_obsolete_term_mapping($_) } @obsolete_term_files);
}

$config->{obsolete_term_mapping} = {
  process_obsolete_term_mapping_files(@obsolete_term_mapping_files)
};

$config->{target_quals} = {};

$config->{gene_ex_qualifiers} =
  $gene_ex_qualifier_util->read_qualifiers($gene_ex_qualifiers);



my $id_counter = PomBase::Chado::IdCounter->new(chado => $chado,
                                                config => $config);

$config->{id_counter} = $id_counter;

for my $chadoprop_terms (['db_creation_datetime', strftime("%Y-%m-%d %H:%M", localtime(time))],
                         ['date_version', $date_version],
                         ['db_date_version', $database]) {

  my $prop_term_name = $chadoprop_terms->[0];
  my $prop_value = $chadoprop_terms->[1];

  my $prop_cvterm =
    $chado->resultset('Cv::Cvterm')
    ->find({ name => $prop_term_name,
             'cv.name' => 'PomBase chadoprop types' },
           { join => 'cv' });

  $chado->resultset('Cv::Chadoprop')->create({
    type_id => $prop_cvterm->cvterm_id(),
    value => $prop_value,
  });
}

my @files = @ARGV;

my $genotype_cache = PomBase::Chado::GenotypeCache->new(chado => $chado);

my $organism = PomBase::Role::OrganismFinder::find_organism_by_taxonid_helper($chado, $taxonid);

my %genes_by_name = ();

while (defined (my $file = shift)) {
  my $load_file = PomBase::Chado::LoadFile->new(chado => $chado,
                                                genotype_cache => $genotype_cache,
                                                genes_by_name => \%genes_by_name,
                                                verbose => $verbose,
                                                config => $config,
                                                organism => $organism);

  $load_file->process_file($file);
}

if(0) {
# populate the phylonode table
my $phylotree = $chado->resultset('Phylogeny::Phylotree')->create(
  {
    name => 'org_hierarchy',
    dbxref => $chado->resultset('General::Dbxref')
      ->find({ accession => 'local:null' }),
  }
);

my $phylo_rs = $chado->resultset('Phylogeny::Phylonode');

my $phylonode_id = 0;
my @phylonodes =
  qw'root Eukaryota Fungi Dikarya Ascomycota Taphrinomycotina
     Schizosaccharomycetes Schizosaccharomycetales Schizosaccharomycetaceae
     Schizosaccharomyces';

for (my $i = 0; $i < @phylonodes; $i++) {
  $phylo_rs->create({ phylonode_id => $i++, left_id => $i,
                      right_id => $i, distance => scalar(@phylonodes) - $i });
}
}

my $uniprot_mapping_loader =
  PomBase::Chado::LoadUniProtMapping->new(chado => $chado,
                                          config => $config,
                                          verbose => $verbose);
$uniprot_mapping_loader->load_uniprot_mapping();

my $extension_processor =
  PomBase::Chado::ExtensionProcessor->new(chado => $chado,
                                          config => $config,
                                          verbose => $verbose,
                                          id_counter => $id_counter);

my $post_process_data = $config->{post_process};

$extension_processor->process($post_process_data,
                              $config->{target_quals}->{is},
                              $config->{target_quals}->{of});

my $paralog_processor =
  PomBase::Chado::ParalogProcessor->new(chado => $chado,
                                        config => $config,
                                        verbose => $verbose);
my $paralog_data = $config->{paralogs};
$paralog_processor->store_all_paralogs($paralog_data);

my $checker = PomBase::Chado::CheckLoad->new(chado => $chado,
                                             config => $config,
                                             verbose => $verbose,
                                             );

warn "counts of unused qualifiers:\n";
while (my ($qual, $count) = each %{$config->{stats}->{unused_qualifiers}}) {
  warn "  $qual: $count\n";
}

if ($test) {
  $checker->check();
}
$guard->commit unless $dry_run;
