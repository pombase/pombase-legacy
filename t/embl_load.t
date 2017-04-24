use strict;
use warnings;
use Test::More tests => 1;

use Test::Deep;

use PomBase::TestUtil;
use PomBase::Chado::LoadFile;
use PomBase::Chado::IdCounter;
use PomBase::Chado::GenotypeCache;
use PomBase::Load;

my $test_util = PomBase::TestUtil->new(load_test_features => 0);
my $chado = $test_util->chado();
my $config = $test_util->config();

my $guard = $chado->txn_scope_guard;

my $id_counter = PomBase::Chado::IdCounter->new(config => $config,
                                                chado => $chado);
$config->{id_counter} = $id_counter;

my $organism = PomBase::Load::init_objects($chado, $config);

my $genotype_cache = PomBase::Chado::GenotypeCache->new(chado => $chado);

my $load_file = PomBase::Chado::LoadFile->new(chado => $chado,
                                              genotype_cache => $genotype_cache,
                                              quiet => 1,
                                              config => $config,
                                              organism => $organism);

$load_file->process_file('data/chromosome1.contig.embl');

$guard->commit();

my $feature_rs = $chado->resultset('Sequence::Feature');

is ($feature_rs->count(), 83);
