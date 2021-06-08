use strict;
use warnings;
use Carp;


use Test::More tests => 4;

BEGIN { use_ok('PomBase::Role::FeatureCvtermCreator') };
BEGIN { use_ok('PomBase::Chado::LoadFeat') };
BEGIN { use_ok('PomBase::Chado::QualifierLoad') };
BEGIN { use_ok('PomBase::Chado::ExtensionProcessor') };
