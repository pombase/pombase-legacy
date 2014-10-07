use strict;
use warnings;
use Test::More tests => 2;

use PomBase::Chado::LoadUniProtMapping;

package LoadUniProtMappingTest;

use Moose;

extends 'PomBase::Chado::LoadUniProtMapping';

sub get_url_contents
{
  return "SPAC2F7.03c\tQ09690\nSPBC2F12.13\tO14343\n";
}

package main;

use PomBase::TestUtil;

my $test_util = PomBase::TestUtil->new();
my $chado = $test_util->chado();
my $config = $test_util->config();

my $map_loader = LoadUniProtMappingTest->new(config => $config,
                                             chado => $chado);

$map_loader->load_uniprot_mapping();

my $c2f12_13 = $chado->resultset('Sequence::Feature')->find({ uniquename => 'SPBC2F12.13' });

is ($c2f12_13->uniquename(), 'SPBC2F12.13');

my @props = $c2f12_13->featureprops();

ok (grep { $_->type()->name() eq 'uniprot_identifier' &&
             $_->value() eq 'O14343' } @props);
