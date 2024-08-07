use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'PomBase',
    license             => 'perl',
    dist_author         => q{Kim Rutherford <kmr44@cam.ac.uk>},
    dist_version_from   => 'lib/PomBase/Load.pm',
    requires            => {
      perl                    => '5.12.0',
      'Bio::Chado::Schema'    => 0,
      'Text::CSV'             => 0,
      'Moose'                 => 0,
      'MooseX::Traits'        => 0,
      'DBIx::Class'           => 0,
      'Bio::SeqIO'            => 0,
      'Carp::Assert'          => 0,
      'Digest::MD5'           => 0,
      'File::Temp'            => 0,
      'Memoize'               => 0,
      'Method::Signatures'    => 0,
      'Module::Find'          => 0,
      'YAML'                  => 0,
      'YAML::Any'             => 0,
      'DBIx::DBStag'          => 0,
      'DBIx::DBSchema'        => 0,
      'LWP::UserAgent'        => 0,
      'Text::Trim'            => 0,
      'Iterator::Simple'      => 0.06,
      'Tie/IxHash'            => 0,
      'Data::Compate'         => 0,
      'Text::CSV::Encoded'    => 0,
      'DBD::Pg'               => 0,
      'Module::Install'       => 0,
    },
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'PomBase-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
