#!/bin/sh -

build_label=$1
version=$2

cd /var/www/pombase/dumps/releases

date_stamp=`date +'%Y-%m-%d'`

release_label="pombase-chado-$2-$date_stamp"

if [ -e $release_label ]
then
  echo "$release_label directory already existing - exiting" 1>&2
  exit 1
fi

echo copying to the new release directory
cp -r ../builds/$1 $release_label

ln -s $release_label/$build_label.dump.gz $release_label.dump.gz

echo "creating DB for $release_label"
dropdb $release_label
createdb $release_label

gzip -d < $release_label.dump.gz | psql -q $release_label

new_terms_obo=/var/pomcur/sources/pombase/pombase_terms-$version.obo.new

(cd ~/git/pombase-chado/; ./script/pombase-export.pl ./load-pombase-chado.yaml ontology --constraint-type=db_name --constraint-value=PBO localhost pombase-chado-v46-2014-08-30 kmr44 kmr44 ) > $new_terms_obo

echo wrote: $new_terms_obo

echo "now update pombase-chado-latest with:"
echo "  rm pombase-chado-latest*"
echo "  ln -s $release_label pombase-chado-latest"
echo "  ln -s $release_label.dump.gz pombase-chado-latest.dump.gz"
echo
echo "and tag release-$version"
