package PomBase::Chado::LoadUniProtMapping;

=head1 NAME

PomBase::Chado::LoadUniProtMapping - Read a mapping file of PomBase IDs to
                                     UniProt IDs and store as featureprops

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomBase::Chado::LoadUniProtMapping

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2013 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use perl5i::2;
use Moose;

use LWP::UserAgent;
use HTTP::Request;

with 'PomBase::Role::ConfigUser';
with 'PomBase::Role::ChadoUser';
with 'PomBase::Role::XrefStorer';
with 'PomBase::Role::FeatureStorer';
with 'PomBase::Role::GetUrl';

has verbose => (is => 'rw');

method load_uniprot_mapping {
  my $url = $self->config()->{pombase_to_uniprot_mapping};

  if (!defined $url) {
    warn "no pombase_to_uniprot_mapping configuation, not loading mapping\n";
    return;
  }

  my $mapping = $self->get_url_contents($url);

  my %map = ();

  for my $line (split /^/, $mapping) {
    chomp $line;

    if ($line =~ /(.*)\t(.*)/) {
      $map{$1} = $2;
    }
  }

  my $rs = $self->chado()->resultset('Sequence::Feature')
    ->search({ 'type.name' => 'gene' }, { join => 'type' });

  while (defined (my $f = $rs->next())) {
    my $uniquename = $f->uniquename();
    if ($map{$uniquename}) {
      $self->store_featureprop($f, 'uniprot_identifier', $map{$uniquename});
    }
  }
}
