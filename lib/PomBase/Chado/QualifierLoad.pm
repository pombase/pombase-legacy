package PomBase::Chado::QualifierLoad;

=head1 NAME

PomBase::Chado::QualifierLoad - Load a Chado database from Sanger PGG EMBL files

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomBase::Chado::QualifierLoad

=over 4

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Kim Rutherford, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 FUNCTIONS

=cut

use perl5i::2;
use Carp qw(cluck);

use Moose;

use Memoize;

has verbose => (is => 'ro', isa => 'Bool');
has quiet => (is => 'ro', isa => 'Bool');

has gene_ex_qualifiers => (is => 'ro', init_arg => undef,
                           lazy_build => 1);
has genotype_cache => (is => 'ro', required => 1,
                       isa => 'PomBase::Chado::GenotypeCache');
has source_file => (is => 'ro', required => 1);

with 'PomBase::Role::ConfigUser';
with 'PomBase::Role::ChadoUser';
with 'PomBase::Role::FeatureDumper';
with 'PomBase::Role::XrefStorer';
with 'PomBase::Role::ChadoObj';
with 'PomBase::Role::DbQuery';
with 'PomBase::Role::CvQuery';
with 'PomBase::Role::CvtermCreator';
with 'PomBase::Role::FeatureCvtermCreator';
with 'PomBase::Role::FeatureFinder';
with 'PomBase::Role::FeatureStorer';
with 'PomBase::Role::Embl::FeatureRelationshipStorer';
with 'PomBase::Role::OrganismFinder';
with 'PomBase::Role::QualifierSplitter';
with 'PomBase::Role::LegacyAlleleHandler';
with 'PomBase::Role::Embl::FeatureRelationshippropStorer';
with 'PomBase::Role::PhenotypeFeatureFinder';
with 'PomBase::Role::GOAnnotationProperties';

method _build_gene_ex_qualifiers {
  my @gene_ex_qualifiers = @{$self->config()->{gene_ex_qualifiers}};

  my %gene_ex_qualifiers = map { ($_, 1) } @gene_ex_qualifiers;

  return \%gene_ex_qualifiers;
}

method find_cv_by_name($cv_name) {
  die 'no $cv_name' unless defined $cv_name;

  return ($self->chado()->resultset('Cv::Cv')->find({ name => $cv_name })
    or die "no cv with name: $cv_name");
}
memoize ('find_cv_by_name');

method add_feature_relationshipprop($feature_relationship, $name, $value) {
  if (!defined $name) {
    die "no name for property\n";
  }
  if (!defined $value) {
    die "no value for $name\n";
  }

  my $type = $self->find_or_create_cvterm($self->objs()->{feature_relationshipprop_type_cv},
                                          $name);

  my $rs = $self->chado()->resultset('Sequence::FeatureRelationshipprop');

  warn "    adding feature_relationshipprop $name => $value\n" if $self->verbose();

  return $rs->create({ feature_relationship_id =>
                         $feature_relationship->feature_relationship_id(),
                       type_id => $type->cvterm_id(),
                       value => $value,
                       rank => 0 });
}

my $current_year = 1900 + (localtime(time))[5];

method get_and_check_date($sub_qual_map) {
  my $date = delete $sub_qual_map->{date};

  if (defined $date) {
    return undef if $date eq '19700101' or $date eq '1970-01-01';

    if ($date =~ /(\d\d\d\d)-?(\d\d)-?(\d\d)/) {
      if ($1 > $current_year) {
        warn "date is in the future: $date\n" unless $self->quiet();
      } else {
        if ($2 < 1 || $2 > 12) {
          warn "month ($2) not in range 1..12\n" unless $self->quiet();
        }
        if ($3 < 1 || $3 > 31) {
          warn "day ($3) not in range 1..31\n" unless $self->quiet();
        }
      }
      $date = "$1-$2-$3";
      return $date;
    } else {
      warn "  unknown date format: $date\n" unless $self->quiet();
    }
  }

  return undef;
}

# look up cvterm by $embl_term_name first, then by GOid, complain
# about mismatches
method add_term_to_gene($pombe_feature, $cv_name, $embl_term_name, $sub_qual_map, $create_cvterm) {
  if ($cv_name eq 'gene_ex') {
    if ($embl_term_name =~ /RNA/) {
      $cv_name = 'PomGeneExRNA';
    } else {
      $cv_name = 'PomGeneExProt';
    }
    my $qualifiers = $sub_qual_map->{qualifier};

    if (defined $qualifiers && @$qualifiers != 0) {
      if (@$qualifiers == 1) {
        my $qualifier = $qualifiers->[0];

        if ($qualifier eq 'present' or $qualifier eq 'absent') {
          $embl_term_name =~ s/\s+level$//;
        }
        $embl_term_name .= " $qualifier";

        delete $sub_qual_map->{qualifier};
      } else {
        die "too many qualifiers for $embl_term_name: @{$qualifiers}\n";
      }
    }
  }

  my $extension = $sub_qual_map->{annotation_extension};
  if (defined $extension && $extension =~ /\|/) {
    # split into multiple annotations
    for my $bit (split /\|/, $extension) {
      my $qual_copy = { %$sub_qual_map };
      $qual_copy->{annotation_extension} = $bit;
      $self->add_term_to_gene($pombe_feature, $cv_name, $embl_term_name, $qual_copy, 0);
    }

    return;
  }

  $embl_term_name =~ s/\s+/ /g;
  $embl_term_name = $embl_term_name->trim();

  my $mapping_conf = $self->config()->{mappings}->{$cv_name};

  if (defined $mapping_conf) {
    $cv_name = $mapping_conf->{new_name};

    my $mapping = $mapping_conf->{mapping};
    my $new_term_id = $mapping->{$embl_term_name};

    if (!defined $new_term_id) {
      die "can't find new term for $embl_term_name in mapping for $cv_name\n";
    }

    my $new_term = $self->find_cvterm_by_term_id($new_term_id);

    if (!defined $new_term) {
      my $obsolete = $self->find_cvterm_by_term_id($new_term_id,
                                                   {
                                                     include_obsolete => 1,
                                                   });

      if (defined $obsolete) {
        die "term '$new_term_id' in $cv_name is obsolete\n";
      } else {
        die "can't find '$new_term_id' in $cv_name\n";
      }
    }

    if ($self->verbose()) {
      print "mapping $embl_term_name to $cv_name/", $new_term->name(), "\n";
    }

    $embl_term_name = $new_term->name();
  }

  my $cv = $self->find_cv_by_name($cv_name);

  my $uniquename = $pombe_feature->uniquename();

  my $qualifier_term_id;

  if ($self->is_go_cv_name($cv_name)) {
    $qualifier_term_id = delete $sub_qual_map->{GOid};
    if (!defined $qualifier_term_id) {
      warn "  no GOid for $uniquename annotation: '$embl_term_name'\n" unless $self->quiet();
      return;
    }
    if ($qualifier_term_id !~ /GO:(.*)/) {
      warn "  GOid doesn't start with 'GO:' for $uniquename: $qualifier_term_id\n" unless $self->quiet();
      return;
    }
  }

  my $cvterm;

  my $obsolete_id;

  if (defined $qualifier_term_id) {
    $obsolete_id = $self->config()->{obsolete_term_mapping}->{$qualifier_term_id};
  }

  if ($create_cvterm) {
    $cvterm = $self->find_or_create_cvterm($cv, $embl_term_name, $qualifier_term_id);
  } else {
    $cvterm = $self->find_cvterm_by_name($cv, $embl_term_name, prefetch_dbxref => 1);

    if (!defined $cvterm) {
      if (defined $obsolete_id) {
        $cvterm = $self->find_cvterm_by_name($cv, "$embl_term_name (obsolete $obsolete_id)",
                                             prefetch_dbxref => 1);
      }
      if (!defined $cvterm && defined $qualifier_term_id) {
        $cvterm = $self->find_cvterm_by_term_id($qualifier_term_id);
        if (!defined $cvterm) {
          die qq(unknown term name "$embl_term_name" and unknown GO ID "$qualifier_term_id"\n) unless $self->quiet();
        }
        if (!$self->config()->{allowed_unknown_term_names}->{$qualifier_term_id}) {
          die "found cvterm by ID, but name doesn't match any cvterm: $qualifier_term_id " .
            "EMBL file: $embl_term_name  Chado name for ID: ", $cvterm->name(), "\n" unless $self->quiet();
        } else {
          warn "This is a warning about code that needs to be removed - " .
            "please tell Kim - details: " .
            "$qualifier_term_id + $embl_term_name";
        }
        $qualifier_term_id = undef;
      }
    }
  }

  if (defined $qualifier_term_id) {
    if ($qualifier_term_id =~ /(.*):(.*)/) {
      my $new_db_name = $1;
      my $new_dbxref_accession = $2;

      my $dbxref = $cvterm->dbxref();
      my $db = $dbxref->db();

      if ($new_db_name ne $db->name()) {
        die "database name for new term ($new_db_name) doesn't match " .
          "existing name (" . $db->name() . ") for term name: $embl_term_name\n";
      }

      if ($new_dbxref_accession ne $dbxref->accession()) {
        my $allowed_mismatch_confs =
          $self->config()->{allowed_term_mismatches}->{$uniquename};

        if (!defined $allowed_mismatch_confs) {
          (my $key = $uniquename) =~ s/\.\d+$//;
          $allowed_mismatch_confs =
            $self->config()->{allowed_term_mismatches}->{$key};
        }

        my $allowed_mismatch_type = undef;
        if (defined $allowed_mismatch_confs &&
            grep {
              my $res =
                $_->{embl_id} eq $qualifier_term_id &&
                $_->{embl_name} eq $embl_term_name;
              if ($res) {
                $allowed_mismatch_type = $_->{winner};
                warn "This is a warning about code that needs to be removed - " .
                  "please tell Kim - details: " .
                  "$qualifier_term_id + $embl_term_name + $new_dbxref_accession";
              }
              $res;
            } @{$allowed_mismatch_confs}) {
          if ($allowed_mismatch_type eq 'ID') {
            $cvterm = $self->find_cvterm_by_term_id($qualifier_term_id);
          } else {
            if ($allowed_mismatch_type eq 'name') {
              # this is the default - fall through
            } else {
              die "unknown mismatch type: $allowed_mismatch_type\n";
            }
          }
        } else {
          my $db_term_id = $db->name() . ":" . $dbxref->accession();
          my $embl_cvterm =
            $self->find_cvterm_by_term_id($qualifier_term_id);
          if (!defined $embl_cvterm) {
            die "internal error, failed to find cvterm for $qualifier_term_id ($db_term_id)\n";
          }
          if (defined $obsolete_id && $db_term_id eq $obsolete_id) {
            # use the cvterm we got from the GOid, not the name
            $cvterm = $embl_cvterm;
          } else {
            die "ID in EMBL file ($qualifier_term_id) " .
              "doesn't match ID in Chado ($db_term_id) " .
              "for EMBL term name $embl_term_name   (Chado term name: ",
              $embl_cvterm->name(), ")\n";
          }
        }
      }
    } else {
      die qq|database ID "$qualifier_term_id" doesn't contain a colon|;
    }
  }

  my @withs = ();

  if ($self->is_go_cv_name($cv_name) || $cv_name eq 'fission_yeast_phenotype') {
    if (defined $sub_qual_map->{with}) {
      if ($sub_qual_map->{with}->length() == 0) {
        die qq("with=" has no value after the "="\n);
      }

      @withs = split /,/, delete $sub_qual_map->{with};

      map {
        if (!/^\w+:[\w\d\.]+$/ && !/^MGI:MGI:/) {
          die qq(with value "$_" should be in the form "DB:ACCESSION"\n);
        }
      } @withs;
    }
  }

  my $db_xref = delete $sub_qual_map->{db_xref};

  if ($self->is_go_cv_name($cv_name) ||
      grep { $_ eq $cv_name } (qw(fission_yeast_phenotype PSI-MOD))) {
    if (!defined $db_xref) {
      die "no db_xref for $embl_term_name ($cv_name)\n";
    }
  }

  my $evidence_code = delete $sub_qual_map->{evidence};

  if (defined $evidence_code) {
    if (grep { $_ eq $cv_name } ('biological_process', 'molecular_function',
                                  'cellular_component', 'gene_ex')) {
      if ($evidence_code eq 'ISS') {
        if (!@withs) {
          die qq(ISS must have a "with="\n);
        }

        if (grep { /^SGD:/ } @withs) {
          warn "    changing ISS to ISO for @withs\n" if $self->verbose();
          $evidence_code = 'ISO';
          if ($db_xref eq 'GO_REF:0000001') {
            $db_xref = 'GO_REF:0000024';
          }
        } else {
          if (grep { /^(Pfam|InterPro):/ } @withs) {
            warn "    changing ISS to ISM for @withs\n" if $self->verbose();
            $evidence_code = 'ISM';
          }
        }
      }
    } else {
      warn "found evidence for $embl_term_name in $cv_name\n" unless $self->quiet();
    }
  } else {
    if (grep { $_ eq $cv_name } ('biological_process', 'molecular_function',
                                 'cellular_component', 'gene_ex')) {
      warn "no evidence for $cv_name annotation: $embl_term_name in ", $uniquename, "\n" unless $self->quiet();
      return;
   }

    if ($cv_name eq 'fission_yeast_phenotype' and $db_xref eq 'PMID:20473289') {
      $evidence_code = 'Microscopy';
    }

    if (!defined $evidence_code) {
      my $config_evidence_code = $self->config()->{auto_evidence_assignment}->{$cvterm->name()};

      if (defined $config_evidence_code) {
        $evidence_code = $config_evidence_code;
      }
    }
  }

  if (!$db_xref && $mapping_conf->{db_xref}) {
    $db_xref = $mapping_conf->{db_xref};
  }

  my $pub = $self->get_pub_from_db_xref($embl_term_name, $db_xref);

  my $is_not = 0;

  my $qualifiers = delete $sub_qual_map->{qualifier};

  $self->maybe_move_predicted($qualifiers, $sub_qual_map);

  my @qualifiers = ();

  if (defined $qualifiers) {
    @qualifiers =
      grep {
        if ($_ eq 'NOT') {
          $is_not = 1;
          0;
        } else {
          1;
        }
      } @$qualifiers;
  }

  if (!defined $cvterm) {
    die qq(couldn't find or create a cvterm for $embl_term_name in $uniquename\n);
  }

  my $chado = $self->chado();

  $chado->txn_begin();

  try {
    my $featurecvterm =
      $self->create_feature_cvterm($pombe_feature, $cvterm, $pub, $is_not);

    my $annotation_throughput = undef;

    if ($cv_name eq 'cat_act' || $cv_name eq 'subunit_composition' ||
        $cv_name eq 'gene_ex') {
      $annotation_throughput = 'low throughput';
    }

    if ($cv_name eq 'PSI-MOD') {
      if ($pub->uniquename() eq 'PMID:19547744') {
        $annotation_throughput = 'high throughput';
      } else {
        $annotation_throughput = 'low throughput';
      }
    }

    if ($cv_name eq 'fission_yeast_phenotype') {
      $self->move_condition_qual($featurecvterm, $sub_qual_map);
      $annotation_throughput = 'low throughput';
    }

    if ($self->is_go_cv_name($cv_name)) {
      $self->add_feature_cvtermprop($featurecvterm, assigned_by => $self->config()->{database_name});

      if ($evidence_code) {
        my $annotation_throughput_type = $self->annotation_throughput_type($evidence_code);
        if ($annotation_throughput_type) {
          $annotation_throughput = $annotation_throughput_type;
        }
      }

      my $new_evidence_code =
        $self->maybe_move_igi($cvterm, $evidence_code, \@qualifiers, \@withs, $sub_qual_map);

      die "no evidence code" unless defined $evidence_code;

      $evidence_code = $new_evidence_code;

      if (defined $sub_qual_map->{from}) {
        my @froms = split /,/, delete $sub_qual_map->{from};
        for (my $i = 0; $i < @froms; $i++) {
          my $from = $froms[$i];
          $self->add_feature_cvtermprop($featurecvterm, from => $from, $i);
        }
      }
    }

    if (!defined $annotation_throughput) {
      $annotation_throughput = 'non-experimental';
    }

    $self->add_feature_cvtermprop($featurecvterm, 'annotation_throughput_type',
                                  $annotation_throughput);

    $self->add_feature_cvtermprop($featurecvterm, 'source_file', $self->source_file());

    for (my $i = 0; $i < @withs; $i++) {
      my $with = $withs[$i];
      if ($with =~ /.:./) {
        $self->add_feature_cvtermprop($featurecvterm, with => $with, $i);
      } else {
        die qq|"with" identifier "$with" is not in the form db:accession\n|;
      }
    }

    $self->add_feature_cvtermprop($featurecvterm, qualifier => [@qualifiers]);

    if (defined $db_xref && $db_xref eq 'PMID:20519959') {
      $self->add_pubmed_20519959_conditions($featurecvterm);
    }

    if (defined $evidence_code) {
      if (!exists $self->config()->{evidence_types}->{$evidence_code}) {
        die "no such evidence code: $evidence_code\n";
      }
      my $evidence =
        $self->config()->{evidence_types}->{$evidence_code}->{name} // $evidence_code;

      $self->add_feature_cvtermprop($featurecvterm, evidence => $evidence);
    }

    if (defined $sub_qual_map->{residue}) {
      $self->add_feature_cvtermprop($featurecvterm,
                                    residue => delete $sub_qual_map->{residue});
    }

    my $expression = undef;

    if (defined $sub_qual_map->{allele} || $cv_name eq 'fission_yeast_phenotype') {
      my $allele = $sub_qual_map->{allele};

      my %args = ();

      if (defined $allele) {
        if ($allele =~ /^.+\(.+\)$/) {
          %args = %{$self->make_allele_data_from_display_name($pombe_feature, $allele,
                                                              \$expression)};
        } else {
          if ($allele eq 'deletion') {
            my $new_name = ($pombe_feature->name() // $pombe_feature->uniquename()) . 'delta';
            $args{name} = $new_name;
            $args{description} = 'deletion';
            $expression = undef;
            warn qq|storing allele=$allele as "$new_name(deletion)"\n| if $self->verbose();
          } else {
            warn qq|allele "$allele" is not in the form "name(description)" - storing as "$allele(unknown)"\n| unless $self->quiet();
            $args{name} = $allele;
            $args{description} = 'unknown';
          }
        }
      } else {
        $args{name} = undef;
        $args{description} = 'unrecorded';
      }

      $args{gene} = $pombe_feature;

      my $allele_type = delete $sub_qual_map->{allele_type} // $self->allele_type_from_desc($args{description}, $pombe_feature->name());

      if (!defined $allele_type || length $allele_type == 0) {
        $allele_type = 'unknown';
        warn "ambiguous or unset allele_type for $args{name}($args{description})\n" unless $self->quiet();
      }
      $args{allele_type} = $allele_type;

      my $genotype_feature = $self->get_genotype_for_allele(\%args, $expression);

      $featurecvterm->feature($genotype_feature);
      $featurecvterm->update();
    }

    if (defined $sub_qual_map->{column_17}) {
      $self->add_feature_cvtermprop($featurecvterm,
                                    gene_product_form_id => delete $sub_qual_map->{column_17});
    }

    my $date = $self->get_and_check_date($sub_qual_map);
    if (defined $date) {
      $self->add_feature_cvtermprop($featurecvterm, date => $date);
    }

    my $sub_qual_copy = { %$sub_qual_map };
    if (delete $sub_qual_map->{annotation_extension}) {
      push @{$self->config()->{post_process}->{$featurecvterm->feature_cvterm_id()}}, {
        feature_cvterm => $featurecvterm,
        qualifiers => $sub_qual_copy
      }
    }

    $self->check_unused_quals(%$sub_qual_map);

    $chado->txn_commit();
  } catch {
    chomp(my $message = $_);
    warn "failed to add annotation: $message\n";
    $chado->txn_rollback();
  };
}

method maybe_move_igi($term, $evidence_code, $qualifiers, $withs, $sub_qual_map) {
  my $dbxref = $term->dbxref();
  my $termid = $dbxref->db()->name() . ':' . $dbxref->accession();

  my %terms = (
    'GO:0034613' => 1,
    'GO:0034501' => 1,
    'GO:0034504' => 1,
    'GO:0034502' => 1,
    'GO:0034504' => 1,
    'GO:0006606' => 1,
    'GO:0034503' => 1);

  return $evidence_code unless $terms{$termid};

  if ($evidence_code && $evidence_code eq 'IGI' &&
      defined $qualifiers && @{$qualifiers} > 0 &&
      grep { $_ eq 'localization_dependency'; } @$qualifiers) {

    if (@$withs) {
      if (@$withs > 1) {
        die "can't handle more than one with qualifier\n";
      }
      my $with = $withs->[0];

      @$withs = ();

      if (exists $sub_qual_map->{annotation_extension}) {
        warn "annotation_extension already exists when converting IGI\n" unless $self->quiet();
      } else {
        $sub_qual_map->{annotation_extension} = "has_input($with)";
        @$qualifiers = grep { $_ ne 'localization_dependency'; } @$qualifiers;

        return 'IMP';
      }
    } else {
      warn "no 'with' qualifier on localization_dependency IGI\n" unless $self->quiet();
    }
  }

  return $evidence_code;
}

method maybe_move_predicted($qualifiers, $sub_qual_map) {
  return unless defined $qualifiers;

  for (my $i = 0; $i < @$qualifiers; $i++) {
    if ($qualifiers->[$i] eq 'predicted') {
      if (exists $sub_qual_map->{evidence} && $sub_qual_map->{evidence} ne 'ISS') {
        warn "trying to assign ISS evidence to a feature that already has evidence\n" unless $self->quiet();
      } else {
        splice @$qualifiers, $i, 1;
        $sub_qual_map->{evidence} = 'ISS';
      }
      last;
    }
  }
}

method move_condition_qual($feature_cvterm, $sub_qual_map) {
  my $ex = $sub_qual_map->{annotation_extension};
  if (defined $ex && $ex =~ /^condition\((.*)\)$/) {
    my $termid = $1;

    if ($termid !~ /PECO:/) {
      die "condition '$termid' isn't a PECO term ID\n";
    }

    my $cvterm = $self->find_cvterm_by_term_id($termid);

    if (!defined $cvterm) {
      die "can't load condition, $termid not found in database\n";
    }

    if ($cvterm->is_obsolete()) {
      die "condition '$termid' is obsolete\n";
    }

    my $dbxref = $cvterm->dbxref();
    my $real_termid = $dbxref->db()->name() . ':' . $dbxref->accession();

    $self->add_feature_cvtermprop($feature_cvterm, condition => $real_termid);
    delete $sub_qual_map->{annotation_extension};
  }
}

method add_pubmed_20519959_conditions($feature_cvterm) {
  my $cvterm_name = $feature_cvterm->cvterm()->name();
  return unless $cvterm_name eq 'inviable' || $cvterm_name eq 'viable';
  my @conditions = qw(PECO:0000012 PECO:0000005 PECO:0000090);

  my @props = $feature_cvterm->feature_cvtermprops();
  my $max_rank = 0;
  for my $prop (@props) {
    if ($prop->type()->name() eq 'condition') {
      if ($prop->rank() > $max_rank) {
        $max_rank = $prop->rank();
      }
    }
  }

  for (my $i = $max_rank + 1; $i < @conditions; $i++) {
    $self->add_feature_cvtermprop($feature_cvterm, condition => $conditions[$i], $i);
  }
}

method add_feature_relationship_pub($relationship, $pub) {
  my $rs = $self->chado()->resultset('Sequence::FeatureRelationshipPub');

  warn "    adding pub ", $pub->pub_id(), " to feature_relationship ",
    $relationship->feature_relationship_id() , "\n" if $self->verbose();

  return $rs->create({ feature_relationship_id =>
                         $relationship->feature_relationship_id(),
                       pub_id => $pub->pub_id() });

}

method process_ortholog($chado_object, $term, $sub_qual_map) {
  warn "    process_ortholog()\n" if $self->verbose();
  my $org_name;
  my $gene_bit;

  my $chado_object_type = $chado_object->type()->name();
  my $chado_object_uniquename = $chado_object->uniquename();

  if ($chado_object_type ne 'gene' && $chado_object_type ne 'pseudogene') {
    warn "  can't apply ortholog to $chado_object_type: $term\n" if $self->verbose();
    return 1;
  }

  my $organism_common_name;

  if ($term =~ /^orthologous to S\. cerevisiae (.*)/) {
    $organism_common_name = 'Scerevisiae';
    $gene_bit = $1;
  } else {
    if ($term =~ /^human\s+(.*?)\s+ortholog$/) {
      $organism_common_name = 'human';
      $gene_bit = $1;
    } else {
      warn "  didn't find ortholog in: $term\n" if $self->verbose();
      return 0;
    }
  }

  my $organism = $self->find_organism_by_common_name($organism_common_name);

  my @gene_names = ();

  for my $gene_name (split /\s+(?:and|or)\s+/, $gene_bit) {
    if ($gene_name =~ /^(\S+)(?:\s+\(([cn])-term\))?$/i) {
      push @gene_names, { name => $1, term => $2 };
    } else {
      warn qq(gene name contains whitespace "$gene_name" from "$term") unless $self->quiet();
      return 0;
    }
  }

  my $date = $self->get_and_check_date($sub_qual_map);

  for my $ortholog_conf (@gene_names) {
    my $ortholog_name = $ortholog_conf->{name};
    my $ortholog_term = $ortholog_conf->{term};

    warn "    creating ortholog from ", $chado_object_uniquename,
      " to $ortholog_name\n" if $self->verbose();

    my $ortholog_feature = undef;
    try {
      $ortholog_feature =
        $self->find_chado_feature($ortholog_name, 1, 1, $organism);
    } catch {
      warn "  caught exception: $_\n" unless $self->quiet();
    };

    if (!defined $ortholog_feature) {
      warn "ortholog ($ortholog_name) not found\n" unless $self->quiet();
      next;
    }

    my $rel_rs = $self->chado()->resultset('Sequence::FeatureRelationship');

    try {
      my $orth_guard = $self->chado()->txn_scope_guard;
      my $rel = $rel_rs->create({ object_id => $chado_object->feature_id(),
                                  subject_id => $ortholog_feature->feature_id(),
                                  type_id => $self->objs()->{orthologous_to_cvterm}->cvterm_id()
                                });

      if (defined $date) {
        $self->add_feature_relationshipprop($rel, date => $date);
      }

      my $qualifier = delete $sub_qual_map->{qualifier};

      if (defined $qualifier) {
        map {
          if ($_ ne 'predicted') {
            $self->add_feature_relationshipprop($rel, 'ortholog qualifier', $_);
          }
        } @$qualifier;
      }

      my $db_xref = delete $sub_qual_map->{db_xref};
      my $pub = $self->get_pub_from_db_xref($term, $db_xref);
      $self->add_feature_relationship_pub($rel, $pub);
      if (defined $ortholog_term) {
        $self->add_feature_relationshipprop($rel, 'subject terminus', $ortholog_term);
      }
      $orth_guard->commit();
      warn "  created ortholog to $ortholog_name\n" if $self->verbose();
    } catch {
      warn "  failed to create ortholog relation from $chado_object_uniquename " .
        "to $ortholog_name: $_\n" unless $self->quiet();
      return 0;
    };
  }

  return 1;
}

method process_paralog($chado_object, $term, $sub_qual_map) {
  warn "    process_paralog()\n" if $self->verbose();
  my $other_gene;

  my $chado_object_type = $chado_object->type()->name();
  my $chado_object_uniquename = $chado_object->uniquename();

  if ($chado_object_type ne 'gene' && $chado_object_type ne 'pseudogene') {
    warn "  can't apply paralog to $chado_object_type: $term\n" if $self->verbose();
    return 0;
  }

  my $related;

  if ($term =~ /^(paralogous|similar|related) to S\. pombe (\S+)(?: \(paralogs?\))?/i) {
    if ($1 eq 'related') {
      $related = 1;
    } else {
      $related = 0;
    }
    my @other_gene_bits = split / and /, $2;

    my $date = $self->get_and_check_date($sub_qual_map);

    push @{$self->config()->{paralogs}->{$chado_object_uniquename}}, {
      other_gene_names => [@other_gene_bits],
      feature => $chado_object,
      related => $related,
      date => $date,
    };

    return 1;
  } else {
    warn "  didn't find paralog in: $term\n" if $self->verbose();
    return 0;
  }
}

sub process_warning {
  my ($self, $chado_object, $term, $sub_qual_map) = @_;

  my $chado_object_type = $chado_object->type()->name();

  warn "    process_warning()\n" if $self->verbose();
  if ($chado_object_type ne 'gene' and $chado_object_type ne 'pseudogene') {
    return 0;
  }

  if ($term =~ /WARNING: (.*)/) {
    $self->add_term_to_gene($chado_object, 'warning', $1,
                            $sub_qual_map, 1);
    return 1;
  } else {
    return 0;
  }
}

method process_family($chado_object, $term, $sub_qual_map) {
  warn "    process_family()\n" if $self->verbose();
  $self->add_term_to_gene($chado_object, 'PomBase family or domain', $term,
                          $sub_qual_map, 1);
  return 1;
}

method process_one_cc($chado_object, $bioperl_feature, $qualifier, $target_curations) {
  my $systematic_id = $chado_object->uniquename();

  warn "    process_one_cc($systematic_id, $bioperl_feature, '$qualifier')\n"
    if $self->verbose();

  my %qual_map = ();

  try {
    %qual_map = $self->split_sub_qualifiers($qualifier);
  } catch {
    warn "  $_: failed to process sub-qualifiers from $qualifier, feature:\n" unless $self->quiet();
    $self->dump_feature($bioperl_feature);
  };

  if (scalar(keys %qual_map) == 0) {
    warn "  no qualifiers\n" if $self->verbose();
    return ();
  }

  my $cv_name = delete $qual_map{cv};
  my $cv_name_qual_exists = defined $cv_name;
  my $term = delete $qual_map{term};

  if (!defined $term || length $term == 0) {
    if ($bioperl_feature->primary_tag() ne 'misc_RNA' || $self->verbose()) {
      warn "no term for: $qualifier\n" unless $self->quiet();
    }
    return ();
  }

  if (!defined $cv_name) {
    map {
      my $long_name = $_;

      if ($term =~ s/^$long_name, *//) {
        my $short_cv_name = $self->objs()->{cv_long_names}->{$long_name};
        $cv_name = $short_cv_name;
      }
    } keys %{$self->objs()->{cv_long_names}};
  }

  my $chado_object_type = $chado_object->type()->name();

  if ($cv_name_qual_exists) {
    if (!($term =~ s/$cv_name, *//)) {

      (my $space_cv_name = $cv_name) =~ s/_/ /g;

      if (!($term =~ s/$space_cv_name, *//)) {
        my $name_substituted = 0;

        if (exists $self->objs()->{cv_alt_names}->{$cv_name}) {
          for my $alt_name (@{$self->objs()->{cv_alt_names}->{$cv_name}}) {
            if ($term =~ s/^$alt_name, *//) {
              $name_substituted = 1;
              last;
            }
            $alt_name =~ s/_/ /g;
            if ($term =~ s/^$alt_name, *//) {
              $name_substituted = 1;
              last;
            }
          }
        }

        if (!$name_substituted) {
          if ($term =~ /(.*?),/) {
            my $cv_name_in_term = $1;
            if ($cv_name_in_term ne $cv_name) {
              if ($chado_object_type ne 'gene' and $chado_object_type ne 'pseudogene') {
                warn qq{cv_name ("$cv_name") doesn't match start of term ("$cv_name_in_term")\n} unless $self->quiet();
              }
            }
          }
        }
      }
    }
  }

  if ($term =~ /^conserved in / && !defined $cv_name) {
    $cv_name = 'species_dist';
  }

  if (defined $cv_name) {
    if (grep { $_ eq $cv_name } keys %{$self->objs()->{cv_alt_names}}) {
      if ($self->objs()->{gene_cvs}->{$cv_name} xor
          ($chado_object_type eq 'gene' or $chado_object_type eq 'pseudogene')) {
        return ();
      }
      try {
        if (defined $qual_map{qualifier}) {
          $self->maybe_move_predicted($qual_map{qualifier}, \%qual_map);
        }
        $self->add_term_to_gene($chado_object, $cv_name, $term, \%qual_map, 1);
      } catch {
        chomp $_;
        warn "$_: failed to load qualifier '$qualifier' from $systematic_id\n" unless $self->quiet();
        $self->dump_feature($bioperl_feature) if $self->verbose();
        return ();
      };
      warn "    loaded: $qualifier\n" if $self->verbose();
    } else {
      warn "CV name not recognised: $qualifier\n" unless $self->quiet();
      return ();
    }
  } else {
      if (!$self->process_ortholog($chado_object, $term, \%qual_map)) {
        if (!$self->process_paralog($chado_object, $term, \%qual_map)) {
          if (!$self->process_warning($chado_object, $term, \%qual_map)) {
            if (!$self->process_family($chado_object, $term, \%qual_map)) {
              warn "qualifier not recognised: $qualifier\n" unless $self->quiet();
              return ();
            }
          }
        }
      }
  }

  $self->check_unused_quals(%qual_map);

  return %qual_map;
}

method process_one_go_qual($chado_object, $bioperl_feature, $qualifier) {
  warn "    go qualifier: $qualifier\n" if $self->verbose();

  my %qual_map = ();

  try {
    %qual_map = $self->split_sub_qualifiers($qualifier);
  } catch {
    warn "  $_: failed to process sub-qualifiers from $qualifier, feature:\n";
    $self->dump_feature($bioperl_feature);
  };

  if (scalar(keys %qual_map) == 0) {
    return ();
  }

  my $aspect = delete $qual_map{aspect};

  if (defined $aspect) {
    my $cv_name = $self->get_go_cv_map()->{uc $aspect};

    my $term = delete $qual_map{term};

    try {
      $self->add_term_to_gene($chado_object, $cv_name, $term, \%qual_map, 0);
    } catch {
      my $systematic_id = $chado_object->uniquename();
      chomp $_;
      warn "$_: failed to load qualifier '$qualifier' from $systematic_id:\n";
      $self->dump_feature($bioperl_feature) if $self->verbose();
      return ();
    };
    warn "    loaded: $qualifier\n" if $self->verbose();
  } else {
    warn "  no aspect for: $qualifier\n" unless $self->quiet();
    return ();
  }

  return %qual_map;
}

method process_product($chado_feature, $product) {
  if ($product =~ /\([^\)]*$|^[^\(]*\)/) {
    warn "unbalanced parenthesis in product: $product\n" unless $self->quiet();
  }

  $self->add_term_to_gene($chado_feature, 'PomBase gene products',
                          $product, {}, 1);
}

method check_unused_quals {
  my %quals = @_;

  if (scalar(keys %quals) > 0) {
    warn "  unprocessed sub qualifiers:\n" if $self->verbose();
    while (my ($key, $value) = each %quals) {
      $self->config()->{stats}->{unused_qualifiers}->{$key}++;
      if (ref $value) {
        $value = "[@$value]";
      }
      warn "   $key => $value\n" if $self->verbose();
    }
  }
}

1;
