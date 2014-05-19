#!/usr/bin/env perl

use perl5i::2;
use Moose;

BEGIN {
  push @INC, 'lib';
};

use PomBase::Chado;

if (@ARGV != 5) {
  die <<"EOF";
$0: needs five arguments:
  eg. $0 database_host database_name user_name password file_of_terms

This script reads a file of GO terms and reports any annotations that use
any of the terms.

The input file may have multiple tab-delimited columns.  The term IDs are
reads from the first column.
EOF
}

my $host = shift;
my $database = shift;
my $username = shift;
my $password = shift;
my $term_file = shift;

my $chado = PomBase::Chado::db_connect($host, $database, $username, $password);

my $dbh = $chado->storage()->dbh();

$dbh->do("
CREATE TEMPORARY TABLE temp_terms_subset (
  db_name text NOT NULL,
  accession text NOT NULL
);
");

my $insert_sth = $dbh->prepare("
INSERT INTO temp_terms_subset(db_name, accession) VALUES (?, ?);
");

open my $fh, '<', $term_file or die "can't open $term_file: $!\n";

while (my $line = <$fh>) {
  chomp $line;
  my @bits = split /\t/, $line;
  my $termid = $bits[0];
  if ($termid =~ /(\w+):(\w+)/) {
    $insert_sth->execute($1, $2);
  } else {
    die qq("$termid" is not in the form "DB:ACCESSION" in line: $line\n);
  }
}

close $fh;

my $query_sth = $dbh->prepare("
SELECT feature_cvterm_id, f.uniquename, f.name AS feature_name,
       db.name || ':' || x.accession AS termid, t.name AS term_name,
       (SELECT value
          FROM feature_cvtermprop fcp
          JOIN cvterm assigned_by_term
            ON assigned_by_term.cvterm_id = fcp.type_id
         WHERE fcp.feature_cvterm_id = fc.feature_cvterm_id AND
               assigned_by_term.name = 'canto_session') AS session,
       (SELECT value
          FROM feature_cvtermprop fcp
          JOIN cvterm assigned_by_term
            ON assigned_by_term.cvterm_id = fcp.type_id
         WHERE fcp.feature_cvterm_id = fc.feature_cvterm_id AND
               assigned_by_term.name = 'assigned_by') AS assigned_by
  FROM feature_cvterm fc
  JOIN feature f ON fc.feature_id = f.feature_id
  JOIN cvterm t ON fc.cvterm_id = t.cvterm_id
  JOIN dbxref x ON x.dbxref_id = t.dbxref_id
  JOIN db ON x.db_id = db.db_id
  JOIN temp_terms_subset subset
    ON subset.db_name = db.name AND subset.accession = x.accession
");

$query_sth->execute();

my $res = $query_sth->fetchall_arrayref({});

for my $row (@$res) {
  print $row->{uniquename}, "\t", $row->{feature_name} // '',
    "\t", $row->{termid}, "\t", $row->{term_name},
    "\t", $row->{session} // '', "\t", $row->{assigned_by}, "\n";
}
