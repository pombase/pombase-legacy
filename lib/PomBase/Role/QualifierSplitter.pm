package PomBase::Role::QualifierSplitter;

=head1 NAME

PomBase::Role::QualifierSplitter - Code for splitter pombe EMBL qualifiers into
                                   sub-qualifiers

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomBase::Role::QualifierSplitter

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use perl5i::2;
use Moose::Role;

my %legal_sub_qualifiers = (
  allele => 1,
  annotation_extension => 1,
  aspect => 1,
  column_17 => 1,
  cv => 1,
  date => 1,
  db_xref => 1,
  evidence => 1,
  from => 1,
  GOid => 1,
  qualifier => 1,
  residue => 1,
  term => 1,
  with => 1,
);

method split_sub_qualifiers($cc_qualifier) {
  my %map = ();

  my @bits = split /;/, $cc_qualifier;

  for my $bit (@bits) {
    $bit = $bit->trim();
    if ($bit =~ /^([^=]+?)\s*=\s*(.*?)$/) {
      my $name = $1;
      my $value = $2;
      if (exists $map{$name}) {
        die "duplicated sub-qualifier '$name' from:
/controlled_curation=\"$cc_qualifier\"";
      }

      if (!$legal_sub_qualifiers{$name}) {
        warn "unknown sub-qualifier: $name\n";
        next;
      }

      if ($name eq 'qualifier') {
        my @bits = split /\|/, $value;
        $value = [@bits];
      }

      $map{$name} = $value;

      if ($name =~ / /) {
        warn "  qualifier name ('$name') contains a space\n" unless $self->verbose() == 10;
      }

      if ($value =~ /=/ && $value !~ /=\s*[\d\.]+/) {
        warn "  qualifier value ('$value') contains an equals '='\n";
      }

      if ($name eq 'cv' && $value =~ / /) {
        warn "  cv name ('$value') contains a space\n" unless $self->verbose() == 10;
      }

      if ($name eq 'db_xref' && $value =~ /\|/) {
        warn "  annotation should be split into two qualifier: $name=$value\n";
      }

      warn "QUAL_NAME: $name\n";
    } else {
      die qq(qualifier not in the form "key=value": "$bit"\n);
    }
  }

  return %map;
}

1;
