#!/bin/bash -

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
cp -r ../builds/$build_label $release_label

(cd $release_label
 mkdir build
 for f in $build_label.{gaf.gz,human-orthologs.txt.gz,phaf.gz}
 do
   mv $f build/
   dest=$(echo $f | sed "s/$build_label/$release_label/")
   ln -s ../build/$f exports/$dest
 done
 mv $build_label.dump.gz build/
 ln -s build/$build_label.dump.gz $release_label.dump.gz
)

ln -s $release_label/$release_label.dump.gz .

echo "creating DB for $release_label"
dropdb $release_label
createdb $release_label

gzip -d < $release_label.dump.gz | psql -q $release_label

new_terms_obo=/var/pomcur/sources/pombase/pombase_terms-$version.obo.new

(cd ~/git/pombase-chado/; ./script/pombase-export.pl ./load-pombase-chado.yaml ontology --constraint-type=db_name --constraint-value=PBO localhost $release_label kmr44 kmr44 ) > $new_terms_obo

echo wrote: $new_terms_obo

echo "now update pombase-chado-latest with:"
echo "  rm pombase-chado-latest*"
echo "  ln -s $release_label pombase-chado-latest"
echo "  ln -s $release_label.dump.gz pombase-chado-latest.dump.gz"
echo
echo and:
echo "  (cd ~/git/pombase-chado; git tag -f release-$version; git push --tags)"
echo "  (cd ~/git/pombase-legacy; git tag -f release-$version; git push --tags)"
echo
echo "update make-db with pombase_terms-$version.obo"
echo
echo "change load-all command line to $version $date_stamp"
