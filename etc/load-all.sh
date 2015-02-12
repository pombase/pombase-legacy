#!/bin/bash -

# run script/make-db first

date

set -o pipefail

HOST=$1
DB=$2
USER=$3
PASSWORD=$4
PREV_VERSION=$5
PREV_DATE=$6

LOG_DIR=`pwd`

SOURCES=/var/pomcur/sources

POMBASE_CHADO=$HOME/git/pombase-chado

GOA_GAF_URL=ftp://ftp.ebi.ac.uk/pub/databases/GO/goa/UNIPROT/gene_association.goa_uniprot.gz

cd $SOURCES/pombe-embl/
svn update || exit 1

cd $POMBASE_CHADO
git pull || exit 1

cd $HOME/git/pombase-legacy
git pull || exit 1

export PERL5LIB=$HOME/git/pombase-chado/lib:$HOME/git/pombase-legacy/lib

cd $LOG_DIR
log_file=log.`date_string`
`dirname $0`/../script/load-chado.pl \
  --mapping "sequence_feature:sequence:$SOURCES/pombe-embl/chado_load_mappings/features-to-so_mapping_only.txt" \
  --mapping "pt_mod:PSI-MOD:$SOURCES/pombe-embl/chado_load_mappings/modification_map.txt" \
  --mapping "phenotype:fission_yeast_phenotype:$SOURCES/pombe-embl/chado_load_mappings/phenotype-map.txt" \
  --gene-ex-qualifiers $SOURCES/pombe-embl/supporting_files/gene_ex_qualifiers \
  --obsolete-term-map $HOME/pombe/go-doc/obsoletes-exact $HOME/git/pombase-legacy/load-pombase-chado.yaml \
  $HOST $DB $USER $PASSWORD $SOURCES/pombe-embl/*.contig 2>&1 | tee $log_file || exit 1

$HOME/git/pombase-legacy/etc/process-log.pl $log_file

echo starting import of biogrid data | tee $log_file.biogrid-load-output

(cd $SOURCES/biogrid
mv BIOGRID-* old/
wget --no-verbose http://thebiogrid.org/downloads/archives/Latest%20Release/BIOGRID-ORGANISM-LATEST.tab2.zip
unzip -q BIOGRID-ORGANISM-LATEST.tab2.zip
if [ ! -e BIOGRID-ORGANISM-Schizosaccharomyces_pombe-*.tab2.txt ]
then
  echo "no pombe BioGRID file found - exiting"
  exit 1
fi
) 2>&1 | tee -a $log_file.biogrid-load-output

cd $HOME/git/pombase-legacy

# see https://sourceforge.net/p/pombase/chado/61/
cat $SOURCES/biogrid/BIOGRID-ORGANISM-Schizosaccharomyces_pombe-*.tab2.txt | $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml biogrid --use_first_with_id  --organism-taxonid-filter=4896 --interaction-note-filter="Contributed by PomBase|contributed by PomBase|triple mutant" --evidence-code-filter='Co-localization' $HOST $DB $USER $PASSWORD 2>&1 | tee -a $LOG_DIR/$log_file.biogrid-load-output

evidence_summary () {
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'evidence') group by value order by count(feature_cvtermprop_id)"
}

echo annotation evidence counts before loading
evidence_summary

echo starting import of GOA GAF data

{
for gaf_file in go_comp.txt go_proc.txt go_func.txt From_curation_tool GO_ORFeome_localizations2.txt
do
  echo reading $gaf_file
  $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --assigned-by-filter=PomBase $HOST $DB $USER $PASSWORD < $SOURCES/pombe-embl/external_data/external-go-data/$gaf_file

  echo counts:
  evidence_summary
done

echo $SOURCES/gene_association.pombase.inf.gaf
GET 'http://build.berkeleybop.org/view/GAF/job/gaf-check-pombase/lastSuccessfulBuild/artifact/gene_association.pombase.inf.gaf' > $SOURCES/gene_association.pombase.inf.gaf
if [ -s $SOURCES/gene_association.pombase.inf.gaf ]
then
  $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings --assigned-by-filter=PomBase,GOC $HOST $DB $USER $PASSWORD < $SOURCES/gene_association.pombase.inf.gaf
else
  echo "Coudn't download gene_association.pombase.inf.gaf - exiting" 1>&2
  exit 1
fi

echo counts after inf:
evidence_summary

echo $SOURCES/gene_association.goa_uniprot.pombe
CURRENT_GOA_GAF="$SOURCES/gene_association.goa_uniprot.gz"
DOWNLOADED_GOA_GAF=$CURRENT_GOA_GAF.downloaded
GET -i $CURRENT_GOA_GAF $GOA_GAF_URL > $DOWNLOADED_GOA_GAF
if [ -s $DOWNLOADED_GOA_GAF ]
then
  mv $DOWNLOADED_GOA_GAF $CURRENT_GOA_GAF
else
  echo "didn't download new $GOA_GAF_URL"
fi

gzip -d < $CURRENT_GOA_GAF | kgrep '\ttaxon:(4896|284812)\t' | $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --use-only-first-with-id --taxon-filter=4896 --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings --assigned-by-filter=InterPro,UniProtKB,UniProt $HOST $DB $USER $PASSWORD

} 2>&1 | tee $LOG_DIR/$log_file.gaf-load-output

echo annotation count after GAF loading:
evidence_summary


echo load quantitative gene expression data

for file in $SOURCES/pombe-embl/external_data/Quantitative_gene_expression_data/*
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml quantitative --organism_taxonid=4896 $HOST $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.quantitative


echo load bulk protein modification files

for file in $SOURCES/pombe-embl/external_data/modification_files/PMID*
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml modification $HOST $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.modification


echo load bulk qualitative gene expression files

for file in $SOURCES/pombe-embl/external_data/qualitative_gene_expression_data/*
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml qualitative --gene-ex-qualifiers=$SOURCES/pombe-embl/supporting_files/gene_ex_qualifiers $HOST $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.qualitative


echo phenotype data from PMID:23697806
$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml phenotype-annotation $HOST $DB $USER $PASSWORD < $SOURCES/pombe-embl/phenotype_mapping/phaf_format_phenotypes.tsv 2>&1 | tee $LOG_DIR/$log_file.phenotypes_from_PMID_23697806-phenotype_mapping

for i in $SOURCES/pombe-embl/external_data/phaf_files/chado_load/PMID_*.*[^~]
do
  f=`basename $i .tsv`
  echo loading phenotype data from $f
  ($POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml phenotype-annotation $HOST $DB $USER $PASSWORD < $i) 2>&1 | tee -a $LOG_DIR/$log_file.phenotypes_from_$f
done

echo load Compara orthologs

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=PMID:19029536 --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction $HOST $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/compara_orths.tsv 2>&1 | tee $LOG_DIR/$log_file.compara_orths


echo load manual pombe to human orthologs: conserved_multi.txt

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=PMID:19029536 --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction $HOST $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/conserved_multi.txt 2>&1 | tee $LOG_DIR/$log_file.manual_multi_orths

echo load manual pombe to human orthologs: conserved_one_to_one.txt

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=PMID:19029536 --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction --add_org_1_term_name='predominantly single copy (one to one)' --add_org_1_term_cv='species_dist' $HOST $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/conserved_one_to_one.txt 2>&1 | tee $LOG_DIR/$log_file.manual_1-1_orths

FINAL_DB=$DB-l1

echo copying $DB to $FINAL_DB
createdb -T $DB $FINAL_DB

CURATION_TOOL_DATA=current-prod-dump.json
scp pomcur@pombe-prod:/var/pomcur/backups/$CURATION_TOOL_DATA .

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml canto-json --organism-taxonid=4896 --db-prefix=PomBase $HOST $FINAL_DB $USER $PASSWORD < $CURATION_TOOL_DATA 2>&1 | tee $LOG_DIR/$log_file.curation_tool_data

echo annotation count after loading curation tool data:
evidence_summary

PGPASSWORD=$PASSWORD psql -U $USER -h $HOST $FINAL_DB -c 'analyze'

echo filtering redundant annotations
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml go-filter $HOST $FINAL_DB $USER $PASSWORD

echo update out of date allele names
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml update-allele-names $HOST $FINAL_DB $USER $PASSWORD

echo change UniProtKB IDs in "with" feature_cvterprop rows to PomBase IDs
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml uniprot-ids-to-local $HOST $FINAL_DB $USER $PASSWORD

echo do GO term re-mapping
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml change-terms \
  --exclude-by-fc-prop="canto_session" \
  --mapping-file=$SOURCES/pombe-embl/chado_load_mappings/GO_mapping_to_specific_terms.txt \
  $HOST $FINAL_DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.go-term-mapping

PGPASSWORD=$PASSWORD psql -U $USER -h $HOST $FINAL_DB -c 'analyze'

echo annotation count after filtering redundant annotations:
evidence_summary

echo running consistency checks
./script/check-chado.pl ./check-db.yaml $HOST $FINAL_DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.chado_checks

POMBASE_EXCLUDED_GO_TERMS=$SOURCES/pombe-embl/supporting_files/GO_terms_excluded_from_pombase.txt
echo report annotations using GO terms from $POMBASE_EXCLUDED_GO_TERMS 2>&1 | tee $LOG_DIR/$log_file.excluded_go_terms
./script/report-subset.pl $HOST $FINAL_DB $USER $PASSWORD $POMBASE_EXCLUDED_GO_TERMS 2>&1 | tee $LOG_DIR/$log_file.excluded_go_terms

POMBASE_EXCLUDED_FYPO_TERMS_OBO=$SOURCES/pombe-embl/mini-ontologies/FYPO_qc_do_not_annotate_subsets.obo
echo report annotations using FYPO terms from $POMBASE_EXCLUDED_FYPO_TERMS_OBO 2>&1 | tee $LOG_DIR/$log_file.excluded_fypo_terms
./script/report-subset.pl $HOST $FINAL_DB $USER $PASSWORD <(perl -ne 'print "$1\n" if /^id:\s*(FYPO:\S+)/' $POMBASE_EXCLUDED_FYPO_TERMS_OBO) 2>&1 | tee $LOG_DIR/$log_file.excluded_fypo_terms

DUMPS_DIR=/var/www/pombase/dumps
BUILDS_DIR=$DUMPS_DIR/builds
CURRENT_BUILD_DIR=$BUILDS_DIR/$FINAL_DB

mkdir $CURRENT_BUILD_DIR
mkdir $CURRENT_BUILD_DIR/logs
mkdir $CURRENT_BUILD_DIR/exports

(
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml gaf --organism-taxon-id=4896 $HOST $FINAL_DB $USER $PASSWORD | gzip -9v > $CURRENT_BUILD_DIR/$FINAL_DB.gaf.gz
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml go-physical-interactions --organism-taxon-id=4896 $HOST $FINAL_DB $USER $PASSWORD | gzip -9v > $CURRENT_BUILD_DIR/exports/pombase-go-physical-interactions.tsv.gz
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml go-substrates --organism-taxon-id=4896 $HOST $FINAL_DB $USER $PASSWORD | gzip -9v > $CURRENT_BUILD_DIR/exports/pombase-go-substrates.tsv.gz
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml interactions --since-date=$PREV_DATE --organism-taxon-id=4896 $HOST $FINAL_DB $USER $PASSWORD | gzip -9v > $CURRENT_BUILD_DIR/exports/pombase-interactions-since-$PREV_VERSION-$PREV_DATE.gz
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml orthologs --organism-taxon-id=4896 --other-organism-taxon-id=9606 $HOST $FINAL_DB $USER $PASSWORD | gzip -9v > $CURRENT_BUILD_DIR/$FINAL_DB.human-orthologs.txt.gz
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml phaf --organism-taxon-id=4896 $HOST $FINAL_DB $USER $PASSWORD | gzip -9v > $CURRENT_BUILD_DIR/$FINAL_DB.phaf.gz
) > $LOG_DIR/$log_file.export_warnings 2>&1

gzip -d < $CURRENT_BUILD_DIR/$FINAL_DB.gaf.gz | /var/pomcur/sources/go-svn/software/utilities/filter-gene-association.pl -e > $LOG_DIR/$log_file.gaf-check

cp $LOG_DIR/$log_file.gaf-load-output $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.biogrid-load-output $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.gaf-check $CURRENT_BUILD_DIR/logs/$log_file.gaf-check
cp $LOG_DIR/$log_file.compara_orths $CURRENT_BUILD_DIR/logs/$log_file.compara-orth-load-output
cp $LOG_DIR/$log_file.manual_multi_orths $CURRENT_BUILD_DIR/logs/$log_file.manual-multi-orths-output
cp $LOG_DIR/$log_file.manual_1-1_orths $CURRENT_BUILD_DIR/logs/$log_file.manual-1-1-orths-output
cp $LOG_DIR/$log_file.curation_tool_data $CURRENT_BUILD_DIR/logs/$log_file.curation-tool-data-load-output
cp $LOG_DIR/$log_file.quantitative $CURRENT_BUILD_DIR/logs/$log_file.quantitative
cp $LOG_DIR/$log_file.qualitative $CURRENT_BUILD_DIR/logs/$log_file.qualitative
cp $LOG_DIR/$log_file.modification $CURRENT_BUILD_DIR/logs/$log_file.modification
cp $LOG_DIR/$log_file.*phenotypes_from_* $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.export_warnings $CURRENT_BUILD_DIR/logs/$log_file.export_warnings
cp $LOG_DIR/$log_file.excluded_go_terms $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.excluded_fypo_terms $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.go-term-mapping $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.chado_checks $CURRENT_BUILD_DIR/logs/

(
echo extension relation counts:
psql $FINAL_DB -c "select count(id), name, base_cv_name from (select p.cvterm_id::text || '_cvterm' as id,
  substring(type.name from 'annotation_extension_relation-(.*)') as name, base_cv_name
  from pombase_feature_cvterm_ext_resolved_terms fc
       join cvtermprop p on p.cvterm_id = fc.cvterm_id
       join cvterm type on p.type_id = type.cvterm_id
  where type.name like 'annotation_ex%'
UNION all select r.cvterm_relationship_id::text ||
  '_cvterm_rel' as id, t.name as name, base_cv_name from cvterm_relationship r join cvterm t on t.cvterm_id = r.type_id join pombase_feature_cvterm_ext_resolved_terms fc on r.subject_id = fc.cvterm_id  where
  t.name <> 'is_a' and r.subject_id in (select cvterm_id from cvterm, cv
  where cvterm.cv_id = cv.cv_id and cv.name = 'PomBase annotation extension terms'))
  as sub group by base_cv_name, name order by base_cv_name, name;
"

echo
echo number of annotations using extensions by cv:

psql $FINAL_DB -c "select count(feature_cvterm_id), base_cv_name from pombase_feature_cvterm_with_ext_parents group by base_cv_name order by count;"
) > $CURRENT_BUILD_DIR/logs/$log_file.extension_relation_counts

(
echo counts of qualifiers grouped by CV name
psql $FINAL_DB -c "select count(fc.feature_cvterm_id), value, base_cv_name from feature_cvtermprop p, pombase_feature_cvterm_ext_resolved_terms fc, cvterm t where type_id = (select cvterm_id from cvterm where name = 'qualifier' and cv_id = (select cv_id from cv where name = 'feature_cvtermprop_type')) and p.feature_cvterm_id = fc.feature_cvterm_id and fc.cvterm_id = t.cvterm_id group by value, base_cv_name order by count desc;"
) > $CURRENT_BUILD_DIR/logs/$log_file.qualifier_counts_by_cv

(
echo all protein family term and annotated genes
psql $FINAL_DB -c "select t.name, db.name || ':' || x.accession as termid, array_to_string(array_agg(f.uniquename), ',') as gene_uniquenames from feature f join feature_cvterm fc on fc.feature_id = f.feature_id join cvterm t on t.cvterm_id = fc.cvterm_id join dbxref x on x.dbxref_id = t.dbxref_id join db on x.db_id = db.db_id join cv on t.cv_id = cv.cv_id where cv.name = 'PomBase family or domain' group by t.name, termid order by t.name, termid;"
) > $CURRENT_BUILD_DIR/logs/$log_file.protein_family_term_annotation

(
echo counts of all annotation by type:
psql $FINAL_DB -c "select count(distinct fc_id), cv_name from (select distinct
fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
and cv.name <> 'PomBase annotation extension terms' UNION select distinct
fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
= t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
and parent_term.cv_id = parent_cv.cv_id and term_cv.name = 'PomBase annotation extension terms' and rel.type_id = rel_type.cvterm_id and rel_type.name =
'is_a') as sub group by cv_name order by count;"
echo

echo annotation counts by evidence code and cv type, sorted by cv name:
psql $FINAL_DB -c "with sub as (select distinct
 fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
 and cv.name <> 'PomBase annotation extension terms' UNION select distinct
 fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
 = t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
 and parent_term.cv_id = parent_cv.cv_id and term_cv.name =
 'PomBase annotation extension terms' and rel.type_id =
 rel_type.cvterm_id and rel_type.name = 'is_a')
 select p.value as ev_code, cv_name, count(fc_id) from sub join
 feature_cvtermprop p on sub.fc_id = p.feature_cvterm_id where type_id
 = (select cvterm_id from cvterm t join cv on t.cv_id = cv.cv_id where
 cv.name = 'feature_cvtermprop_type' and t.name = 'evidence') group by
 p.value, cv_name order by cv_name;"
echo

echo annotation counts by evidence code and cv type, sorted by count:
psql $FINAL_DB -c "with sub as (select distinct
 fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
 and cv.name <> 'PomBase annotation extension terms' UNION select distinct
 fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
 = t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
 and parent_term.cv_id = parent_cv.cv_id and term_cv.name =
 'PomBase annotation extension terms' and rel.type_id =
 rel_type.cvterm_id and rel_type.name = 'is_a')
 select p.value as ev_code, cv_name, count(fc_id) from sub join
 feature_cvtermprop p on sub.fc_id = p.feature_cvterm_id where type_id
 = (select cvterm_id from cvterm t join cv on t.cv_id = cv.cv_id where
 cv.name = 'feature_cvtermprop_type' and t.name = 'evidence') group by
 p.value, cv_name order by count;"
echo

echo annotation counts by evidence code and cv type, sorted by cv evidence code:
psql $FINAL_DB -c "with sub as (select distinct
 fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
 and cv.name <> 'PomBase annotation extension terms' UNION select distinct
 fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
 feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
 = t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
 and parent_term.cv_id = parent_cv.cv_id and term_cv.name =
 'PomBase annotation extension terms' and rel.type_id =
 rel_type.cvterm_id and rel_type.name = 'is_a')
 select p.value as ev_code, cv_name, count(fc_id) from sub join
 feature_cvtermprop p on sub.fc_id = p.feature_cvterm_id where type_id
 = (select cvterm_id from cvterm t join cv on t.cv_id = cv.cv_id where
 cv.name = 'feature_cvtermprop_type' and t.name = 'evidence') group by
 p.value, cv_name order by p.value;"
echo

echo total:
psql $FINAL_DB -c "select count(distinct fc_id) from (select distinct
fc.feature_cvterm_id as fc_id, cv.name as cv_name from cvterm t,
feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and cv.cv_id = t.cv_id
and cv.name <> 'PomBase annotation extension terms' UNION select distinct
fc.feature_cvterm_id as fc_id, parent_cv.name as cv_name from cvterm t,
feature_cvterm fc, cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and term_cv.cv_id
= t.cv_id and t.cvterm_id = subject_id and parent_term.cvterm_id = object_id
and parent_term.cv_id = parent_cv.cv_id and term_cv.name = 'PomBase annotation extension terms' and rel.type_id = rel_type.cvterm_id and rel_type.name =
'is_a') as sub;"

echo
echo counts of annotation from Canto, by type:
sub_query="(select
 distinct fc.feature_cvterm_id as fc_id, cv.name as cv_name from
 cvterm t, feature_cvterm fc, cv where fc.cvterm_id = t.cvterm_id and
 cv.cv_id = t.cv_id and cv.name <> 'PomBase annotation extension
 terms' and fc.feature_cvterm_id in (select feature_cvterm_id from
 feature_cvtermprop where type_id in (select cvterm_id from cvterm
 where name = 'canto_session')) UNION select distinct fc.feature_cvterm_id
 as fc_id, parent_cv.name as cv_name from cvterm t, feature_cvterm fc,
 cv term_cv, cvterm_relationship rel, cvterm parent_term, cv
 parent_cv, cvterm rel_type where fc.cvterm_id = t.cvterm_id and
 term_cv.cv_id = t.cv_id and t.cvterm_id = subject_id and
 parent_term.cvterm_id = object_id and parent_term.cv_id =
 parent_cv.cv_id and term_cv.name = 'PomBase annotation extension
 terms' and rel.type_id = rel_type.cvterm_id and rel_type.name =
 'is_a' and fc.feature_cvterm_id in (select feature_cvterm_id from
 feature_cvtermprop where type_id in (select cvterm_id from cvterm
 where name = 'canto_session'))) as sub"
psql $FINAL_DB -c "select count(distinct fc_id), cv_name from $sub_query group by cv_name order by count;"
psql $FINAL_DB -c "select count(distinct fc_id) as total from $sub_query;"

 ) > $CURRENT_BUILD_DIR/logs/$log_file.annotation_counts_by_cv


DB_BASE_NAME=`echo $DB | sed 's/-v[0-9]$//'`

cp -r $SOURCES/current_build_files/$DB_BASE_NAME/* $CURRENT_BUILD_DIR/


cp $LOG_DIR/*.txt $CURRENT_BUILD_DIR/logs/

mkdir $CURRENT_BUILD_DIR/pombe-embl
cp -r $SOURCES/pombe-embl/* $CURRENT_BUILD_DIR/pombe-embl/

psql $FINAL_DB -c 'grant select on all tables in schema public to public;'

DUMP_FILE=$CURRENT_BUILD_DIR/$FINAL_DB.dump.gz

echo dumping to $DUMP_FILE
pg_dump $FINAL_DB | gzip -9v > $DUMP_FILE

rm -f $DUMPS_DIR/latest_build
ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/latest_build

date
