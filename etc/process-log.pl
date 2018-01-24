#!/usr/bin/perl -w

use perl5i::2;
use Moose;

open my $name_mismatches, '>', 'mismatches.txt' or die;
open my $unknown_term_names, '>', 'unknown_term_names.txt' or die;
open my $ortholog_problems, '>', 'ortholog_problems.txt' or die;
open my $qual_problems, '>', 'qualifier_problems.txt' or die;
open my $unknown_cv_names, '>', 'unknown_cv_names.txt' or die;
open my $mapping_problems, '>', 'mapping_problems.txt' or die;
open my $cv_name_mismatches, '>', 'cv_name_mistaches.txt' or die;
open my $pseudogene_mismatches, '>', 'pseudogene_mismatches.txt' or die;
open my $synonym_match_problems, '>', 'synonym_match_problems.txt' or die;
open my $duplicated_sub_qual_problems, '>', 'duplicated_sub_qual_problems.txt' or die;
open my $target_problems, '>', 'target_problems.txt' or die;
open my $evidence_problems, '>', 'evidence_problems.txt' or die;
open my $db_xref_problems, '>', 'db_xref_problems.txt' or die;
open my $identifier_problems, '>', 'identifier_problems.txt' or die;
open my $missing_products, '>', 'missing_products.txt' or die;
open my $feature_warnings, '>', 'feature_warnings.txt' or die;
open my $misc_term_warnings, '>', 'misc_term_warnings.txt' or die;
open my $all_warnings, '>', 'all_warnings.txt' or die;

my $prev_line = '';
my $gene = '';

my @qual_patterns = (
  'no allele qualifier for phenotype',
  'no evidence.*for',
  'no term for:',
  'qualifier not recognised',
  'unknown term name.*and unknown GO ID',
  'annotation extension qualifier .* not understood',
  'failed to add annotation extension',
  'in annotation extension for',
  'unbalanced parenthesis in product',
  '^qualifier \(.*\) has',
  'not in the form',
  'isn\'t a PECO term ID',
  'duplicated extension',
  'gene expression annotations must have',
  'not a valid qualifier',
  'feature has no systematic_id',
  'failed to add annotation',
  'failed to load qualifier',
  'trying to store an allele',
  'in annotation extension for .* parse identifier',
  'qualifier value .* contains an equals',
  'qualifier name .* contains a space',
  'has \d+ /.* qualifier\(s\)',
  'has more than one',
  'unknown date format',
  'ignoring .*systematic_id=.* on',
  'month .*\d+.* not in range',
  'unknown qualifier:',
);

my $qual_pattern = join '|', @qual_patterns;

while (defined (my $line = <>)) {
  if ($line =~ /ID in EMBL file/) {
    print $all_warnings "$line";
    print $name_mismatches "$gene: $line";
    next;
  }
  if ($line =~ /found cvterm by ID/) {
    print $all_warnings "$line";
    print $unknown_term_names "$gene: $line";
    next;
  }
  if ($line =~ /failed to create ortholog|ortholog.*not found|failed to create paralog/) {
    print $all_warnings "$line";
    print $ortholog_problems "$gene: $line";
    next;
  }
  if ($line =~ /didn't process: /) {
    print $all_warnings "$line";
    chomp $prev_line;
    chomp $line;
    print $qual_problems "$gene: $line  - error: $prev_line\n";
    next;
  }
  if ($line =~ /CV name not recognised/) {
    print $all_warnings "$line";
    print $unknown_cv_names "$gene: $line";
    next;
  }
  if ($line =~ /^no db_xref for/) {
    print $all_warnings $line;
    print $db_xref_problems "$gene: $line";
    next;
  }
  if ($line =~ /$qual_pattern/) {
    print $all_warnings "$line";
    print $qual_problems "$gene: $line";
    next;
  }
  if ($line =~ /can't find new term for .* in mapping/) {
    print $all_warnings "$line";
    print $mapping_problems "$gene: $line";
    next;
  }
  if ($line =~ /^processing (.*)/) {
    if ($1 eq 'mRNA SPBC460.05.1') {
      $gene = '';
    } else {
      $gene = $1;
    }
    next;
  }
  if ($line =~ /duplicated sub-qualifier '(.*)'/) {
    $line =~ s/^\s+//;
    $line =~ s/\s*from:\s*//;
    print $all_warnings "$line\n";
    print $duplicated_sub_qual_problems "$gene: $line\n";
    next;
  }
  if ($line =~ /cv_name .* doesn't match start of term .*/) {
    print $all_warnings "$line";
    print $cv_name_mismatches "$gene: $line";
    next;
  }
  if ($line =~ m! has /colour=13 but isn't a pseudogene!) {
    print $all_warnings $line;
    print $pseudogene_mismatches "$gene: $line";
    next;
  }
  if ($line =~ /more than one cvtermsynonym found for (.*) at .*/) {
    print $all_warnings $line;
    print $synonym_match_problems qq($gene: "$1" matches more than one term\n);
    next;
  }
  if ($line =~ /problem with .*target|problem (with target annotation of|on gene)|no "target .*" in /) {
    print $all_warnings $line;
    print $target_problems $line;
    next;
  }
  if ($line =~ /no evidence for: |no such evidence code: /) {
    print $all_warnings $line;
    print $evidence_problems "$gene: $line";
    next;
  }
  if ($line =~ /(can't find feature .*)/ && $line !~ /skipping|warning in [0-9a-f]+/) {
    print $all_warnings "$1\n";
    if (defined $gene && length $gene > 0) {
      print $identifier_problems "$gene: $1\n";
    } else {
      print $identifier_problems "$line";
    }
    next;
  }
  if ($line =~ m:A CDS/transcript was referenced but|has no uniquename|gene name contains whitespace|no SO type for:) {
    print $all_warnings $line;
    print $feature_warnings "$gene: $line";
    next;
  }
  if ($line =~ /no product for/) {
    print $all_warnings $line;
    print $missing_products "$gene: $line";
    next;
  }
  if ($line =~ /GOid doesn't start with/ ||
     $line =~ /no GOid for/) {
    print $all_warnings $line;
    print $misc_term_warnings "$gene: $line";
    next;
  }

  $prev_line = $line;
}
