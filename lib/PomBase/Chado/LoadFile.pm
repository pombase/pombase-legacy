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

use perl5i::2;
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

has verbose => (is => 'ro', isa => 'Bool');
has quiet => (is => 'ro', isa => 'Bool', default => 0);
has organism => (is => 'ro',
                 required => 1,
                );

method process_file($file) {
  my $chado = $self->chado();
  my $verbose = $self->verbose();
  my $config = $self->config();

  my $feature_loader =
    PomBase::Chado::LoadFeat->new(organism => $self->organism(),
                                  config => $self->config(),
                                  chado => $self->chado(),
                                  verbose => $self->verbose(),
                                  quiet => $self->quiet());

  warn "reading from: $file\n" unless $self->quiet();

  my $io = Bio::SeqIO->new(-file => $file, -format => "embl" );
  my $seq_obj = $io->next_seq;

  my $display_id = $seq_obj->display_id();
  my $chromosome_cvterm = $self->get_cvterm('sequence', 'chromosome');
  my $md5 = Digest::MD5->new;
  $md5->add($seq_obj->seq());

  my %create_args = (
    type_id => $chromosome_cvterm->cvterm_id(),
    uniquename => $display_id,
    name => undef,
    organism_id => $self->organism()->organism_id(),
    residues => $seq_obj->seq(),
    seqlen => length $seq_obj->seq(),
    md5checksum => $md5->hexdigest(),
  );

  my $chromosome =
    $chado->resultset('Sequence::Feature')->create({%create_args});

  $self->store_featureprop($chromosome, 'ena_id',
                           $config->{contig_ena_ids}->{$display_id});

  my $anno_collection = $seq_obj->annotation;

  my %no_systematic_id_counts = ();

  for my $bioperl_feature ($seq_obj->get_SeqFeatures) {
    try {
      my $chado_object =
        $feature_loader->process($bioperl_feature, $chromosome);
    } catch {
      warn "  failed to process feature: $_\n" unless $self->quiet();
    }
  }

  $feature_loader->finalise($chromosome);
}
