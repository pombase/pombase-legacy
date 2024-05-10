#!/usr/bin/env perl

use strict;
use warnings;

$/ = '';

while (<>) {
  s/\n+\z/\n/;
  if (/^name:\s*(.*?)\s*$/m) {
    my $term_name = $1;
    if (/^\s*synonym: "(.*)" EXACT PomBase_display_name \[.*\]\s*$/m) {
      my $display_name = $1;
      if (length $display_name > 0) {
        s/^name:\s*(.*?)\s*$/name: $display_name/m;
      }
      $_ .= qq|synonym: "PomBase_original_PRO_term_name: $term_name" EXACT [PomBase:auto]\n|;
    }
  }
  
  print "$_\n";
}
