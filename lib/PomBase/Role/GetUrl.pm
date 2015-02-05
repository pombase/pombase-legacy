package PomBase::Role::GetUrl;

=head1 NAME

PomBase::Role::GetUrl - Code for reading from a URL

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomBase::Role::GetUrl

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2013 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use perl5i::2;
use Moose::Role;

=head2

 Usage   : my $contents = $obj->get_url_contents($some_url);
 Function: Read from a URL and return the contents as a string

=cut

method get_url_contents
{
  my $url = shift;

  local $ENV{FTP_PASSIVE} = 1;

  my $ua = LWP::UserAgent->new;
  $ua->agent('PomBase');

  my $req = HTTP::Request->new(GET => $url);
  my $res = $ua->request($req);

  if ($res->is_success()) {
    if ($res->content()) {
      return $res->content();
    } else {
      die "query returned no content: $url\n";
    }
  } else {
    die "Couldn't read from $url: ", $res->status_line, "\n";
  }
}
