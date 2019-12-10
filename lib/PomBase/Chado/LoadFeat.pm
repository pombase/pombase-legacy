package PomBase::Chado::LoadFeat;

=head1 NAME

PomBase::Chado::LoadFeat - Code for loading a feature into Chado

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomBase::Chado::LoadFeat

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

use Tie::IxHash;

use PomBase::Chado::QualifierLoad;

with 'PomBase::Role::ConfigUser';
with 'PomBase::Role::ChadoUser';
with 'PomBase::Role::DbQuery';
with 'PomBase::Role::CvQuery';
with 'PomBase::Role::FeatureDumper';
with 'PomBase::Role::Embl::SystematicID';
with 'PomBase::Role::XrefStorer';
with 'PomBase::Role::FeatureStorer';
with 'PomBase::Role::CvtermCreator';
with 'PomBase::Role::FeatureCvtermCreator';
with 'PomBase::Role::CoordCalculator';
with 'PomBase::Role::QualifierSplitter';
with 'PomBase::Role::Embl::FeatureRelationshipStorer';
with 'PomBase::Role::FeatureSequenceStorer';
with 'PomBase::Role::SequenceTranslator';

has organism => (is => 'ro',
                 required => 1,
                );
has transcript_data => (is => 'ro', isa => 'HashRef',
                  init_arg => undef,
                  default => sub {
                    tie my %transcript_data, 'Tie::IxHash';
                    return \%transcript_data;
                  },
                );
has qual_load => (is => 'ro', isa => 'PomBase::Chado::QualifierLoad',
                  init_arg => undef,
                  lazy => 1,
                  builder => '_build_qual_load');
has verbose => (is => 'ro', isa => 'Bool');
has quiet => (is => 'ro', isa => 'Bool');

has gene_objects => (is => 'ro', init_arg => undef, isa => 'HashRef',
                     default => sub { {} });
has genotype_cache => (is => 'ro', required => 1,
                       isa => 'PomBase::Chado::GenotypeCache');
has source_file => (is => 'ro', required => 1);

method _build_qual_load {
  my $chado = $self->chado();
  my $config = $self->config();
  my $verbose = $self->verbose();
  my $quiet = $self->quiet();

  if ($verbose && $quiet) {
    die "LoadFeat: can't be verbose and quiet at the same time";
  }

  my $short_source_file = $self->source_file() =~ s|.*/||r;

  return PomBase::Chado::QualifierLoad->new(chado => $chado,
                                            genotype_cache => $self->genotype_cache(),
                                            verbose => $verbose,
                                            quiet => $quiet,
                                            config => $config,
                                            source_file => $short_source_file,
                                          );
}

my %feature_loader_conf = (
  CDS => {
    save => 1,
    transcript => 1,
    so_type => 'mRNA',
  },
  misc_RNA => {
    save => 1,
    transcript => 1,
    so_type => 'ncRNA',
  },
  ncRNA => {
    save => 1,
    transcript => 1,
    so_type => 'ncRNA',
  },
  tRNA => {
    save => 1,
    transcript => 1,
    so_type => 'tRNA',
  },
  snoRNA => {
    save => 1,
    transcript => 1,
    so_type => 'snoRNA',
  },
  snRNA => {
    save => 1,
    transcript => 1,
    so_type => 'snRNA',
  },
  rRNA => {
    save => 1,
    transcript => 1,
    so_type => 'rRNA',
  },
  LTR => {
    so_type => 'long_terminal_repeat',
  },
  repeat_region => {
    so_type => 'repeat_region',
  },
  misc_difference => {
    so_type => 'SNP',
  },
  "5'UTR" => {
    save => 1,
    so_type => 'five_prime_UTR',
    collected => 1,
  },
  "3'UTR" => {
    save => 1,
    so_type => 'three_prime_UTR',
    collected => 1,
  },
  "exon" => {
    so_type => undef,
    collected => 1,
  },
  "intron" => {
    so_type => 'intron',
    collected => 1,
  },
  misc_feature => {
    so_type => 'region',
  },
  gap => {
    so_type => 'gap',
  },
  conflict => {
    so_type => 'sequence_conflict',
  },
  polyA_signal => {
    so_type => 'polyA_signal_sequence',
  },
  polyA_site => {
    so_type => 'polyA_site',
  },
  promoter => {
    so_type => 'promoter',
  },
  rep_origin => {
    so_type => 'origin_of_replication',
  },
);

my %so_transcript_types = (pseudogenic_transcript => 1);

map {
  my $conf = $feature_loader_conf{$_};
  if ($conf->{transcript}) {
    $so_transcript_types{$conf->{so_type}} = 1;
  }
} keys %feature_loader_conf;

method prepare_transcript_data($transcript_uniquename, $gene_uniquename) {
  my $data;

  if (defined $self->transcript_data()->{$transcript_uniquename}) {
    $data = $self->transcript_data()->{$transcript_uniquename};
  } else {
    $data = {};
    $self->transcript_data()->{$transcript_uniquename} = $data;
  }

  push @{$data->{"5'UTR_features"}}, ();
  push @{$data->{"3'UTR_features"}}, ();
  push @{$data->{"intron_features"}}, ();

  return $data;
}

method save_transcript($feature, $uniquename, $gene_uniquename) {
  my $feat_type = $feature->primary_tag();
  my $so_type = $feature_loader_conf{$feat_type}->{so_type};

  if (!defined $uniquename) {
    warn "$feat_type feature has no uniquename\n" unless $self->quiet();
    return;
  }

  if (!defined $so_type) {
    use Data::Dumper;
    $Data::Dumper::Maxdepth = 10;
    die "can't save transcript for $uniquename",
      Dumper([$feat_type, $feature, $gene_uniquename, $feature_loader_conf{$feat_type}]);
  }

#  warn "SAVE_TRANSCRIPT: $uniquename\n";

  my $data = $self->prepare_transcript_data($uniquename, $gene_uniquename);

  $data->{bioperl_feature} = $feature;
  $data->{so_type} = $so_type;
  $data->{gene_uniquename} = $gene_uniquename;
  $data->{transcript_so_type} =
    $feature_loader_conf{$feat_type}->{so_type};
}

method save_utr($feature, $uniquename, $transcript_uniquename, $gene_uniquename) {
  if (!defined $transcript_uniquename) {
    warn "no transcript_uniquename passed to save_utr() for UTR for $uniquename\n";
    return;
  }

  my $feat_type = $feature->primary_tag();
  my $so_type = $feature_loader_conf{$feat_type}->{so_type};

  my $data = $self->prepare_transcript_data($transcript_uniquename, $gene_uniquename);

  my %feature_data = (
    bioperl_feature => $feature,
    chado_feature => undef,
  );

  push @{$self->transcript_data()->{$transcript_uniquename}->{"${feat_type}_features"}},
       {%feature_data};
}

method process($feature, $chromosome) {
  my $feat_type = $feature->primary_tag();
  my $so_type = $feature_loader_conf{$feat_type}->{so_type};

  if (!defined $so_type) {
    warn "no SO type for $feat_type - skipping\n" unless $self->quiet();
    return;
  }

  if ($feature->has_tag("SO")) {
    my @so_quals = $feature->get_tag_values("SO");

    if (@so_quals > 1) {
      warn "more than one /SO= qualifier\n" unless $self->quiet();
    }

    my $so_term = $self->find_cvterm_by_term_id($so_quals[0]);

    warn "found a /SO= qualifier for $so_quals[0]\n" if $self->verbose();

    if (defined $so_term) {
      warn "changing $so_type to ", $so_term->name(), "\n" if $self->verbose();
      $so_type = $so_term->name();
    } else {
      warn "can't find cvterm for: ", $so_quals[0], "\n" unless $self->quiet();
    }
  }

  my $this_feature_type_conf = $feature_loader_conf{$feat_type};

  my ($uniquename, $transcript_uniquename, $gene_uniquename, $has_systematic_id) =
    $self->get_uniquename($feature, $so_type, $this_feature_type_conf->{transcript});

  if (!$self->quiet()) {
    warn "processing $feat_type $uniquename",
      (defined $gene_uniquename ? " from gene: $gene_uniquename" : ""), "\n"
  }

  if ($this_feature_type_conf->{save}) {
    if ($so_type =~ /UTR/) {
      $self->save_utr($feature, $uniquename, $transcript_uniquename, $gene_uniquename);
    } else {
      $self->save_transcript($feature, $uniquename, $gene_uniquename);
    }
    return;
  }

  my $chado_feature =
    $self->store_feature_and_loc($feature, $chromosome, $so_type);

  if ($this_feature_type_conf->{collected}) {
    if (!$has_systematic_id) {
      warn "  $uniquename has no uniquename - skipping\n" unless $self->quiet();
      return;
    }

    my %feature_data = (
      bioperl_feature => $feature,
      chado_feature => $chado_feature,
    );

    push @{$self->transcript_data()->{$transcript_uniquename}->{"${feat_type}_features"}},
         {%feature_data};
  }

  $self->process_qualifiers($feature, $chado_feature);

  return $chado_feature;
}

method store_product($bioperl_feature, $chado_feature, $uniquename) {
  if ($bioperl_feature->has_tag("product")) {
    my @products = $bioperl_feature->get_tag_values("product");
    if (@products > 1) {
      warn "  $uniquename has more than one product\n" unless $self->quiet();
    } else {
      if (length $products[0] == 0) {
        warn "  zero length product for $uniquename\n" unless $self->quiet();
      } else {
        $self->qual_load()->process_product($chado_feature, $products[0]);
      }
    }
  } else {
    warn "  no product for $uniquename\n" unless $self->quiet();
  }
}

method store_note($feature, $note) {
  $self->store_featureprop($feature, 'comment', $note);
}

method store_ec_number($feature, $ec_number) {
  $self->qual_load()->add_term_to_gene($feature, 'EC numbers',
                                       $ec_number, {}, 1);
}

my %colour_map = (
  2 => 'published',
  4 => 'transposon',
  6 => 'dubious',
  7 => 'biological role inferred',
  8 => 'Schizosaccharomyces pombe specific protein, uncharacterized',
  10 => 'conserved unknown',
  12 => 'Schizosaccharomyces specific protein, uncharacterized',
  13 => 'pseudogene',
);

method store_colour($feature, $colour) {
  my $cvterm_name = $colour_map{$colour};

  if (!defined $cvterm_name) {
    warn "not storing /colour=$colour - unknown type\n" unless $self->quiet();
    return;
  }

  if ($cvterm_name eq 'pseudogene') {
    if ($feature->type()->name() ne 'pseudogene') {
      warn $feature->uniquename(), " has /colour=13 but isn't a pseudogene\n" unless $self->quiet();
    }

    return;
  }

  my $cvterm = $self->get_cvterm('PomBase gene characterisation status',
                                 $cvterm_name);

  if (!defined $cvterm) {
    die "can't find cvterm for $cvterm_name\n";
  }

  my $feature_cvterm =
    $self->create_feature_cvterm($feature, $cvterm,
                                 $self->find_or_create_pub('null'), 0);

  $self->add_feature_cvtermprop($feature_cvterm, 'annotation_throughput_type',
                                'non-experimental');
}

method get_target_curations($bioperl_feature) {
  my @ret = ();

  if ($bioperl_feature->has_tag('controlled_curation')) {
    for my $cc ($bioperl_feature->get_tag_values('controlled_curation')) {
      my %qual_map = ();

      try {
        %qual_map = $self->split_sub_qualifiers($cc);
      } catch {
        warn "  $_: failed to process sub-qualifiers from $cc:\n" unless $self->quiet();
      };

      my $term = delete $qual_map{term};

      if (defined $term && $term =~ /^target is /) {
        if ($term =~ /^target is (\S+)$/) {
          push @ret, { target => $1,
                       %qual_map };
        } else {
          warn "can't understand this target qualifier: $term\n" unless $self->quiet();
        }
      }
    }
  }

  return @ret;
}

method store_feature_db_xref($feature, $db_xref) {
  if ($db_xref =~ /(.+):(.*)/) {
    my $db_name = $1;
    my $db_dest_tables = $self->config()->{db_dest_tables};
    my $db_dest_table = $db_dest_tables->{$db_name};
    if (defined $db_dest_table) {
      if ($db_dest_table eq 'dbxref') {
        $self->add_feature_dbxref($feature, $db_xref);
      } else {
        if ($db_dest_table eq 'pub') {
          my $pub = $self->find_or_create_pub($db_xref);

          $self->create_feature_pub($feature, $pub);
        } else {
          warn qq|not storing /db_xref="$db_xref" - unknown table "$db_dest_table" | .
            "configured in db_dest_tables\n";
        }
      }

    } else {
      warn qq|no destination table configured for $db_name (set "db_dest_tables")\n|;
    }
  } else {
    warn "can't store /db_xref=$db_xref - it is not in the form: " .
      '"DB:ACCESSION"\n';
  }

}

my %handled_qualifiers = (
  systematic_id => 1,
  obsolete_name => 1,
  synonym => 1,
  gene => 1,
  product => 1,
  SO => 1,
  GO => 1,
  controlled_curation => 1,
  colour => 1,
  note => 1,
  primary_name => 1,
  fasta_file => 1,
  clustalx_file => 1,
  pseudo => 1,
  codon_start => 1,
  partial => 1,
  transl_table => 1,
  shared_id => 1,
  db_xref => 1,
  EC_number => 1,
  reserved_name => 1,
  other_transcript => 1,
  protein_id => 1,
);

method process_qualifiers($bioperl_feature, $chado_object) {
  my $type = $bioperl_feature->primary_tag();
  my $verbose = $self->verbose();

  my $uniquename = $chado_object->uniquename();

  my @target_curations = $self->get_target_curations($bioperl_feature);

  if ($bioperl_feature->has_tag("controlled_curation")) {
    for my $value ($bioperl_feature->get_tag_values("controlled_curation")) {
      my %unused_quals =
        $self->qual_load()->process_one_cc($chado_object, $bioperl_feature, $value,
                                           \@target_curations);
      warn "\n" if $verbose;
    }
  }

  my $chado_object_type = $chado_object->type()->name();

  my @tags = $bioperl_feature->all_tags();

  map { $self->{tag_counts}->{$chado_object_type}->{$_}++ } @tags;

  $self->{feature_counts}->{$chado_object_type}++;

  if ($bioperl_feature->has_tag("note")) {
    for my $note ($bioperl_feature->get_tag_values("note")) {
      $self->store_note($chado_object, $note);
    }
  }
  if ($bioperl_feature->has_tag("db_xref")) {
    # store feature /db_xrefs in pub or dbxref tables
    for my $db_xref_value ($bioperl_feature->get_tag_values("db_xref")) {
      $self->store_feature_db_xref($chado_object, $db_xref_value);
    }
  }

  if ($chado_object_type eq 'gene' || $chado_object_type eq 'pseudogene') {
    if ($bioperl_feature->has_tag("EC_number")) {
      my @ec_numbers = $bioperl_feature->get_tag_values("EC_number");
      for my $ec_number (@ec_numbers) {
        $self->store_ec_number($chado_object, $ec_number);
      }

      if ($type ne 'CDS') {
        warn "$uniquename $type has ", scalar(@ec_numbers), " /EC_number qualifier(s)" unless $self->quiet()
      }
    }

    if ($bioperl_feature->has_tag("colour")) {
      my @colours = $bioperl_feature->get_tag_values("colour");

      if (@colours > 1) {
        warn "$type $uniquename has ", scalar(@colours), " /colours qualifier(s)" unless $self->quiet()
      }

      $self->store_colour($chado_object, $colours[0]);
    }
  } else {
    if ($bioperl_feature->has_tag("GO")) {
      for my $value ($bioperl_feature->get_tag_values("GO")) {
        my %unused_quals =
          $self->qual_load()->process_one_go_qual($chado_object, $bioperl_feature, $value);
        warn "\n" if $verbose;
      }
    }
  }
}

method get_mrna_sequence($exons) {
  return join '', map { $_->residues() } @$exons;
}

method store_feature_parts($uniquename, $bioperl_feature, $chromosome, $so_type) {
  my $chado = $self->chado();

  my @coords_list = $self->coords_of_feature($bioperl_feature);
  my @new_parts = ();

  for (my $i = 0; $i < @coords_list; $i++) {
    my ($start, $end) = @{$coords_list[$i]};
    my $prefix = "$uniquename:$so_type:";
    my $part_uniquename = $prefix . ($i + 1);
    my $chado_sub_feature =
      $self->store_feature($part_uniquename, undef, [], $so_type,
                           $self->organism());

    if ($bioperl_feature->has_tag("db_xref")) {
      for my $dbxref_value ($bioperl_feature->get_tag_values("db_xref")) {
        $self->store_feature_db_xref($chado_sub_feature, $dbxref_value);
      }
    }
    push @new_parts, $chado_sub_feature;

    my $strand = $bioperl_feature->location()->strand();

    $self->store_location($chado_sub_feature, $chromosome, $strand,
                          $start, $end);
    $self->store_feature_sequence($chado_sub_feature, $chromosome, $strand,
                                  $start, $end);
  }

  return @new_parts;
}

method store_transcript_parts($bioperl_cds, $chromosome, $transcript_so_type, $utrs_5_prime, $utrs_3_prime, $introns) {
  my $uniquename = ($bioperl_cds->get_tag_values('systematic_id'))[0];
  if ($uniquename !~ /\.\d$/) {
    $uniquename .= '.1';
  }

  my $chado = $self->chado();
  my $cds_location = $bioperl_cds->location();
  my $transcript_start = $cds_location->start();
  my $transcript_end = $cds_location->end();

  my @utrs_data = (@$utrs_5_prime, @$utrs_3_prime);

  for my $utr_data (@utrs_data) {
    my $featureloc = $utr_data->{bioperl_feature}->location();
    my $utr_start = $featureloc->start();
    my $utr_end = $featureloc->end();

    if ($utr_start < $transcript_start) {
      $transcript_start = $utr_start;
    }
    if ($utr_end > $transcript_end) {
      $transcript_end = $utr_end;
    }
  }

  my $exon_so_type;

  if ($bioperl_cds->has_tag('pseudo')) {
    $transcript_so_type = 'pseudogenic_transcript';
    $exon_so_type = 'pseudogenic_exon';
  } else {
    $exon_so_type = 'exon';
  }

  my $chado_transcript = $self->store_feature($uniquename, undef, [],
                                              $transcript_so_type,
                                              $self->organism());
  my $strand = $bioperl_cds->location()->strand();

  my $phase = undef;

  if ($transcript_so_type eq 'mRNA') {
    $phase = 0;
    if ($bioperl_cds->has_tag("codon_start")) {
      my @codon_starts = $bioperl_cds->get_tag_values("codon_start");

      if (@codon_starts > 1) {
        warn "$uniquename has ", scalar(@codon_starts), " /codon_start qualifier(s)\n" unless $self->quiet()
      }

      my $codon_start = $codon_starts[0];

      if ($codon_start == 1) {
        # use default - no phase
      } else {
        if ($codon_start == 2 || $codon_start == 3) {
          $phase = $codon_start - 1;
        } else {
          warn "$uniquename has an illegal /codon_start =$codon_start\n" unless $self->quiet();
        }
      }
    }
  }

  $self->store_location($chado_transcript, $chromosome, $strand,
                        $transcript_start, $transcript_end, $phase);

  my @exons = $self->store_feature_parts($uniquename, $bioperl_cds,
                                         $chromosome, $exon_so_type);

  my $mrna_sequence = $self->get_mrna_sequence(\@exons);

  $chado_transcript->residues($mrna_sequence);
  $chado_transcript->update();

  for (my $i = 0; $i < @exons; $i++) {
    my $exon = $exons[$i];
    my $rank = $i + 1;
    $self->store_feature_rel($exon, $chado_transcript, 'part_of', 0, $rank);
  }

  for my $utr_data (@$utrs_5_prime) {
    my @chado_utrs = $self->store_feature_parts($uniquename,
                                                $utr_data->{bioperl_feature},
                                                $chromosome, "five_prime_UTR");
    for my $chado_utr (@chado_utrs) {
      $self->store_feature_rel($chado_utr, $chado_transcript, 'part_of');
    }
  }

  for my $utr_data (@$utrs_3_prime) {
    my @chado_utrs = $self->store_feature_parts($uniquename,
                                                $utr_data->{bioperl_feature},
                                                $chromosome, "three_prime_UTR");
    for my $chado_utr (@chado_utrs) {
      $self->store_feature_rel($chado_utr, $chado_transcript, 'part_of');
    }
  }

  for my $intron (@$introns) {
    $self->store_feature_rel($intron->{chado_feature}, $chado_transcript, 'part_of');
  }

  if ($bioperl_cds->has_tag("partial")) {
    $self->store_featureprop($chado_transcript, "partial_sequence", "yes")
  }

  if ($transcript_so_type eq 'mRNA') {
    my $chado_peptide = $self->store_feature("$uniquename:pep", undef,
                                             [], 'polypeptide',
                                             $self->organism());
    my $is_mito = $chromosome->uniquename() eq 'MISPCG';
    my ($prot_seq, $stats) = $self->translate_sequence($mrna_sequence, $phase, $is_mito);

    $chado_peptide->residues($prot_seq);
    $chado_peptide->update();

    $self->store_featureprop($chado_peptide, "molecular_weight", $stats->{molecular_weight});
    $self->store_featureprop($chado_peptide, "average_residue_weight", $stats->{average_residue_weight});
    $self->store_featureprop($chado_peptide, "charge_at_ph7", $stats->{charge_at_ph7});
    $self->store_featureprop($chado_peptide, "isoelectric_point", $stats->{isoelectric_point});
    $self->store_featureprop($chado_peptide, "codon_adaptation_index", $stats->{codon_adaptation_index});

    $self->store_feature_rel($chado_peptide, $chado_transcript, 'derives_from');

    $self->store_location($chado_peptide, $chromosome, $strand,
                          $transcript_start, $transcript_end);

    $self->store_product($bioperl_cds, $chado_peptide, $uniquename);
  } else {
    $self->store_product($bioperl_cds, $chado_transcript, $uniquename);
  }

  return ($transcript_start, $transcript_end, $chado_transcript);
}


method finalise($chromosome) {
  while (my ($uniquename, $feature_data) = each %{$self->transcript_data()}) {
    my $gene_start = 9999999999;
    my $gene_end = -1;

    my $so_type = $feature_data->{so_type};

    if (!$so_type) {
      warn "A CDS/transcript was referenced but doesn't exist: ",
        ($uniquename =~ s/\.\d$//r), "\n";
      next;
    }

    my $transcript_bioperl_feature = $feature_data->{bioperl_feature};

    my $transcript_so_type = $feature_data->{transcript_so_type};


    if (!defined $transcript_bioperl_feature) {
      die "no feature for $uniquename\n";
    }

    warn "processing $so_type $uniquename\n" unless $self->quiet();

    my ($transcript_start, $transcript_end, $chado_transcript) =
      $self->store_transcript_parts($transcript_bioperl_feature,
                                    $chromosome,
                                    $transcript_so_type,
                                    $feature_data->{"5'UTR_features"},
                                    $feature_data->{"3'UTR_features"},
                                    $feature_data->{"intron_features"},
                                  );

    if ($transcript_start < $gene_start) {
      $gene_start = $transcript_start;
    }

    if ($transcript_end > $gene_end) {
      $gene_end = $transcript_end;
    }

    $self->process_qualifiers($transcript_bioperl_feature, $chado_transcript);

    for my $tag ($transcript_bioperl_feature->all_tags()) {
      if (!$handled_qualifiers{$tag}) {
        warn "unknown qualifier: /$tag\n";
      }
    }

    my $gene_uniquename = $feature_data->{gene_uniquename};
    my $chado_gene = $self->gene_objects()->{$gene_uniquename};

    if (!defined $chado_gene) {
      $chado_gene = $self->store_feature_and_loc($transcript_bioperl_feature,
                                                 $chromosome, 'gene',
                                                 $gene_start, $gene_end);
      $self->gene_objects()->{$gene_uniquename} = $chado_gene;

      $self->process_qualifiers($transcript_bioperl_feature, $chado_gene);
    }

    $self->store_feature_rel($chado_transcript, $chado_gene, 'part_of');
  }

  warn "counts of EMBL qualifiers by feature type and un-handled qualifiers:\n" unless $self->quiet();

  for my $feat_type (keys %{$self->{tag_counts}}) {
    my %counts = %{$self->{tag_counts}->{$feat_type}};

    my $feat_count = $self->{feature_counts}->{$feat_type};

    warn "  $feat_type ($feat_count)\n" unless $self->quiet();

    for my $tag_name (keys %counts) {
      next if $handled_qualifiers{$tag_name};
      my $count = $counts{$tag_name};
      warn "    $tag_name: $count\n" unless $self->quiet();
    }
  }
}
