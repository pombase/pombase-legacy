package PomBase::Chado::LoadFile;

=head1 NAME

PomBase::Chado::LoadFile - Load an EMBL file into Chado

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomBase::Chado::LoadFile

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use strict;
use warnings;
use Carp;

use Try::Tiny;

use Moose;

use PomBase::Chado::LoadFeat;
use Digest::MD5;
use Bio::SeqIO;

with 'PomBase::Role::ConfigUser';
with 'PomBase::Role::ChadoUser';
with 'PomBase::Role::DbQuery';
with 'PomBase::Role::CvQuery';
with 'PomBase::Role::XrefStorer';
with 'PomBase::Role::FeatureStorer';
with 'PomBase::Role::OrganismFinder';

has verbose => (is => 'ro', isa => 'Bool');
has quiet => (is => 'ro', isa => 'Bool', default => 0);
has organism => (is => 'ro',
                         required => 1,
                       );
has genotype_cache => (is => 'ro', required => 1,
                       isa => 'PomBase::Chado::GenotypeCache');
has genes_by_name => (is => 'ro', required => 1);

sub process_file {
  my $self = shift;
  my $file = shift;

  my $chado = $self->chado();
  my $verbose = $self->verbose();
  my $config = $self->config();

  my $organism = $self->organism();

  my $feature_loader =
    PomBase::Chado::LoadFeat->new(organism => $organism,
                                  config => $self->config(),
                                  chado => $self->chado(),
                                  genotype_cache => $self->genotype_cache(),
                                  genes_by_name => $self->genes_by_name(),
                                  verbose => $self->verbose(),
                                  quiet => $self->quiet(),
                                  source_file => $file,
                                );

  warn "reading from: $file\n" unless $self->quiet();

  my $io = Bio::SeqIO->new(-file => $file, -format => "embl" );
  my $seq_obj = $io->next_seq;

  my $ena_id = $seq_obj->display_id();

  my %chr_name_map = (
    "japonicus_chr1" => "chromosome_1",
    "japonicus_chr2" => "chromosome_2",
    "japonicus_chr3" => "chromosome_3",
    "CU329670" => "chromosome_1",
    "CU329671" => "chromosome_2",
    "CU329672" => "chromosome_3",
    "FP565355" => "mating_type_region",
    "MK618072" => "mitochondrial",
    "AB325691" => "chr_II_telomeric_gap",
    "AF547983" => "mitochondrial",
    "KE651166" => "supercont5.1",
    "KE651167" => "supercont5.2",
    "KE651168" => "supercont5.3",
    "KE651169" => "supercont5.4",
    "KE651170" => "supercont5.5",
    "KE651171" => "supercont5.6",
    "KE651172" => "supercont5.7",
    "KE651173" => "supercont5.8",
    "KE651174" => "supercont5.9",
    "KE651175" => "supercont5.10",
    "KE651176" => "supercont5.11",
    "KE651177" => "supercont5.12",
    "KE651178" => "supercont5.13",
    "KE651179" => "supercont5.14",
    "KE651180" => "supercont5.15",
    "KE651181" => "supercont5.16",
    "KE651182" => "supercont5.17",
    "KE651183" => "supercont5.18",
    "KE651184" => "supercont5.19",
    "KE651185" => "supercont5.20",
    "KE651186" => "supercont5.21",
    "KE651187" => "supercont5.22",
    "KE651188" => "supercont5.23",
    "KE651189" => "supercont5.24",
    "KE651190" => "supercont5.25",
    "KE651191" => "supercont5.26",
    "KE651192" => "supercont5.27",
    "KE651193" => "supercont5.28",
    "KE651194" => "supercont5.29",
    "KE651195" => "supercont5.30",
    "KE651196" => "supercont5.31",
    "KE651197" => "supercont5.32",
  );

  my $chr_uniquename = $chr_name_map{$ena_id};

  my $chromosome_cvterm = $self->get_cvterm('sequence', 'chromosome');
  my $md5 = Digest::MD5->new;
  $md5->add($seq_obj->seq());

  my %create_args = (
    type_id => $chromosome_cvterm->cvterm_id(),
    uniquename => $chr_uniquename,
    name => undef,
    organism_id => $organism->organism_id(),
    residues => $seq_obj->seq(),
    seqlen => length $seq_obj->seq(),
    md5checksum => $md5->hexdigest(),
  );

  my $chromosome =
    $chado->resultset('Sequence::Feature')->create({%create_args});

  $self->store_featureprop($chromosome, 'ena_id', $ena_id);

  my $anno_collection = $seq_obj->annotation;

  my %no_systematic_id_counts = ();

  for my $bioperl_feature ($seq_obj->get_SeqFeatures) {
    try {
      my $chado_object =
        $feature_loader->process($bioperl_feature, $chromosome, $organism);
    } catch {
      warn "  failed to process feature: $_\n" unless $self->quiet();
    }
  }

  $feature_loader->finalise($chromosome);
}

1;
