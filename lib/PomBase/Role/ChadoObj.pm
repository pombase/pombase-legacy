package PomBase::Role::ChadoObj;

=head1 NAME

PomBase::Role::ChadoObj - A cache of Chado objects

=head1 SYNOPSIS

=head1 AUTHOR

Kim Rutherford C<< <kmr44@cam.ac.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<kmr44@cam.ac.uk>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PomBase::Role::ChadoObj

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

requires 'chado';

has objs => (is => 'ro', isa => 'HashRef[Str]', default => sub { {} });

my %go_cv_map = (
  P => 'biological_process',
  F => 'molecular_function',
  C => 'cellular_component',
);

method get_go_cv_map
{
  return \%go_cv_map;
}

method is_go_cv_name($cv_name) {
  return grep { $_ eq $cv_name } values %go_cv_map;
}

method BUILD
{
  my $chado = $self->chado();

  my $db_rs = $chado->resultset('General::Db');

  my %dbs_objects = ();

  $self->objs()->{cv_alt_names} = {
    genome_org => ['genome organisation', 'genome organization'],
    sequence_feature => ['sequence feature', 'protein sequence feature'],
    species_dist => ['species distribution'],
    phenotype => [],
    pt_mod => ['modification'],
    gene_ex => ['expression', 'gene expression'],
    m_f_g => ['misc functional group'],
    name_description => ['name description'],
    pathway => [],
    complementation => [],
    ex_tools => ['experimental tools'],
    misc => [],
    warning => [],
    DNA_binding_specificity => ['DNA binding specificity'],
    subunit_composition => [],
    cat_act => ['catalytic activity'],
    disease_associated => ['disease associated'],
  };

  map {
    my $cv_name = $_;
    if (!$self->objs()->{cv_alt_names}->{$cv_name}) {
      $self->objs()->{cv_alt_names}->{$cv_name} = [];
    }
  } keys %{$self->config()->{cvs}};

  $self->objs()->{cv_long_names} = {
    'genome organisation' => 'genome_org',
    'genome organization' => 'genome_org',
    'protein sequence feature' => 'sequence_feature',
    'sequence feature' => 'sequence_feature',
    'species distribution' => 'species_dist',
    'modification' => 'pt_mod',
    'expression' => 'gene_ex',
    'gene expression' => 'gene_ex',
    'misc functional group' => 'm_f_g',
    'name description' => 'name_description',
    'catalytic activity' => 'cat_act',
    'phenotype' => 'phenotype',
    'disease associated' => 'disease_associated',
    'DNA binding specificity' => 'DNA_binding_specificity',
    'subunit composition' => 'subunit_composition',
    'experimental tools' => 'ex_tools',
  };

  $self->objs()->{gene_cvs} = {
    map { ($_, 1) } qw(gene_ex species_dist name_description misc warning genome_org phenotype m_f_g pathway complementation ex_tools DNA_binding_specificity subunit_composition cat_act disease_associated)
  };

  for my $cv_name (keys %{$self->objs()->{cv_alt_names}}) {
    if (!exists $self->objs()->{cv_long_names}->{$cv_name}) {
      $self->objs()->{cv_long_names}->{$cv_name} = $cv_name;
    }
  }


  my $pombase_name = $self->config()->{db_name_for_cv};

  my $pombase_db = $db_rs->find_or_create({ name => $pombase_name });

  $dbs_objects{$go_cv_map{P}} = $pombase_db;
  $dbs_objects{$go_cv_map{F}} = $pombase_db;
  $dbs_objects{$go_cv_map{C}} = $pombase_db;

  for my $cv_name (keys %{$self->config->{cvs}}) {
    $dbs_objects{$cv_name} = $pombase_db;
  }

  $self->objs()->{pombase_db} = $pombase_db;

  $dbs_objects{feature_cvtermprop_type} = $pombase_db;
  $dbs_objects{feature_relationshipprop_type} = $pombase_db;

  $self->objs()->{dbs_objects} = \%dbs_objects;

  my $cv_rs = $chado->resultset('Cv::Cv');

  $cv_rs->find_or_create({ name => 'feature_cvtermprop_type' });

  $self->objs()->{feature_relationshipprop_type_cv} =
    $cv_rs->find_or_create({ name => 'feature_relationshipprop_type' });

  $self->objs()->{publication_type_cv} =
    $cv_rs->find({ name => 'PomBase publication types' });

  my $cvterm_rs = $chado->resultset('Cv::Cvterm');

  for my $extra_cv_name (keys %{$self->objs()->{cv_alt_names}}) {
    next if exists $self->config()->{mappings}->{$extra_cv_name};

    $cv_rs->find_or_create({ name => $extra_cv_name });

    if (!defined $self->objs()->{dbs_objects}->{$extra_cv_name}) {
      $self->objs()->{dbs_objects}->{$extra_cv_name} = $pombase_db;
    }
  }

  $self->objs()->{null_pub_cvterm} =
    $self->find_cvterm_by_name('PomBase publication types', 'null');

  $self->objs()->{null_pub} =
    $chado->resultset('Pub::Pub')->find_or_create({
      uniquename => 'null',
      type_id => $self->objs()->{null_pub_cvterm}->cvterm_id(),
    });

  $self->objs()->{orthologous_to_cvterm} =
    $chado->resultset('Cv::Cvterm')->find({ name => 'orthologous_to' });
  $self->objs()->{paralogous_to_cvterm} =
    $chado->resultset('Cv::Cvterm')->find({ name => 'paralogous_to' });

  $self->objs()->{synonym_type_cv} = $self->get_cv('synonym_type');

  $self->objs()->{exact_cvterm} =
    $self->find_cvterm_by_name($self->objs()->{synonym_type_cv}, 'exact');
}

1;
