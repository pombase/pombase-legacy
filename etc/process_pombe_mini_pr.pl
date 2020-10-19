#!/usr/bin/env perl

use strict;
use warnings;

$/ = '';

while (<>) {
  if (/^\s*synonym: "(.*)" EXACT PomBase_display_name \[.*\]\s*$/m) {
    my $display_name = $1;
    s/^name:\s*(.*?)\s*$/name: $display_name/m;
  }

  print;
}
