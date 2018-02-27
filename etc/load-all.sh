#!/bin/bash -

# run script/make-db first

date

set -eu
set -o pipefail

HOST="$1"
DATE="$2"
USER="$3"
PASSWORD="$4"
PREV_VERSION="$5"
CURRENT_VERSION=`echo $PREV_VERSION | perl -ne 'if (/^v?(\d+)$/) { print "v" . ($1+1) . "\n"; } else { print "vUNKNOWN" }'`
PREV_DATE="$6"

die() {
  echo $1 1>&2
  exit 1
}

POMCUR=/var/pomcur
SOURCES=$POMCUR/sources

(cd ~/chobo/; git pull) || die "Failed to update Chobo"
(cd ~/git/pombase-chado; git pull) || die "Failed to update pombase-chado"
(cd ~/git/pombase-legacy; git pull) || die "Failed to update pombase-legacy"

(cd $SOURCES/pombe-embl/; svn update || exit 1)

(cd ~/git/pombase-legacy
 export PATH=$HOME/chobo/script/:/usr/local/owltools-v0.2.1-255-geff650b/OWLTools-Runner/bin/:$PATH
 export OWLTOOLS_CHADO_CLOSURE=$HOME/git/pombase-chado/script/owltools-chado-closure.pl
 export PERL5LIB=$HOME/git/pombase-chado:$HOME/chobo/lib/
 time nice -19 ./script/make-db $DATE "$HOST" $USER $PASSWORD) || die "make-db failed"

DB_DATE_VERSION=$DATE
DB=pombase-build-$DB_DATE_VERSION

LOG_DIR=`pwd`

POMBASE_CHADO=$HOME/git/pombase-chado
POMBASE_LEGACY=$HOME/git/pombase-legacy

GOA_GAF_URL=ftp://ftp.ebi.ac.uk/pub/databases/GO/goa/UNIPROT/goa_uniprot_all.gaf.gz

cd $POMBASE_CHADO
git pull || exit 1

cd $POMBASE_LEGACY
git pull || exit 1

export PERL5LIB=$HOME/git/pombase-chado/lib:$POMBASE_LEGACY/lib

(cd $SOURCES
wget -q -N ftp://ftp.ebi.ac.uk/pub/databases/genenames/new/tsv/hgnc_complete_set.txt ||
    echo failed to download HGNC data
wget -q -N http://downloads.yeastgenome.org/curation/chromosomal_feature/SGD_features.tab ||
    echo failed to download SGD data
)

$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml organisms \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/pombase_organism_config.tsv

$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
    --organism-taxonid=9606 --uniquename-column=1 --name-column=2 --feature-type=gene \
    --product-column=3 \
    --ignore-lines-matching="^hgnc_id.symbol" --ignore-short-lines \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/hgnc_complete_set.txt

echo loading protein coding genes from SGD data file
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
    --organism-taxonid=4932 --uniquename-column=4 --name-column=5 \
    --product-column=16 \
    --column-filter="2=ORF,blocked_reading_frame" --feature-type=gene \
    --ignore-short-lines \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/SGD_features.tab

for so_type in ncRNA snoRNA
do
  echo loading $so_type genes from SGD data file
  $POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
      --organism-taxonid=4932 --uniquename-column=4 --name-column=5 \
      --column-filter="2=${so_type}_gene" --feature-type=gene \
      --ignore-short-lines \
      "$HOST" $DB $USER $PASSWORD < $SOURCES/SGD_features.tab
done

cd $LOG_DIR
log_file=log.`date +'%Y-%m-%d-%H-%M-%S'`
`dirname $0`/../script/load-chado.pl --taxonid=4896 \
  --mapping "sequence_feature:sequence:$SOURCES/pombe-embl/chado_load_mappings/features-to-so_mapping_only.txt" \
  --mapping "pt_mod:PSI-MOD:$SOURCES/pombe-embl/chado_load_mappings/modification_map.txt" \
  --mapping "phenotype:fission_yeast_phenotype:$SOURCES/pombe-embl/chado_load_mappings/phenotype-map.txt" \
  --gene-ex-qualifiers $SOURCES/pombe-embl/supporting_files/gene_ex_qualifiers \
  --obsolete-term-map $SOURCES/go-svn/doc/obsoletes-exact $POMBASE_LEGACY/load-pombase-chado.yaml \
  "$HOST" $DB $USER $PASSWORD $SOURCES/pombe-embl/*.contig 2>&1 | tee $log_file || exit 1

$POMBASE_LEGACY/etc/process-log.pl $log_file

echo loading features without coordinates
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
    --organism-taxonid=4896 --uniquename-column=1 --name-column=2 --feature-type=promoter \
    --reference-column=6 --date-column=7 \
    --parent-feature-id-column=5 --parent-feature-rel-column=4 \
    --ignore-lines-matching="^Identifier" \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/features_without_coordinates.txt

echo starting import of biogrid data | tee $log_file.biogrid-load-output

(cd $SOURCES/biogrid
wget -q -N https://downloads.thebiogrid.org/Download/BioGRID/Latest-Release/BIOGRID-ORGANISM-LATEST.tab2.zip ||
    die failed to download new BIOGRID data

unzip -qo BIOGRID-ORGANISM-LATEST.tab2.zip
if [ ! -e BIOGRID-ORGANISM-Schizosaccharomyces_pombe*.tab2.txt ]
then
  echo "no pombe BioGRID file found - exiting"
  exit 1
fi
) 2>&1 | tee -a $log_file.biogrid-load-output

cd $POMBASE_LEGACY

# see https://sourceforge.net/p/pombase/chado/61/
cat $SOURCES/biogrid/BIOGRID-ORGANISM-Schizosaccharomyces_pombe*.tab2.txt | $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml biogrid --use_first_with_id  --organism-taxonid-filter=284812:4896 --interaction-note-filter="Contributed by PomBase|contributed by PomBase|triple mutant" --evidence-code-filter='Co-localization' "$HOST" $DB $USER $PASSWORD 2>&1 | tee -a $LOG_DIR/$log_file.biogrid-load-output

evidence_summary () {
  DB=$1
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'evidence') group by value order by count(feature_cvtermprop_id)" | cat
}

refresh_views () {
  for view in \
    pombase_annotated_gene_features_per_publication \
    pombase_feature_cvterm_with_ext_parents \
    pombase_feature_cvterm_no_ext_terms \
    pombase_feature_cvterm_ext_resolved_terms \
    pombase_genotypes_alleles_genes_mrna \
    pombase_extension_rels_and_values \
    pombase_genes_annotations_dates
  do
    psql $DB -c "REFRESH MATERIALIZED VIEW $view;"
  done
}

echo annotation evidence counts before loading
evidence_summary $DB

echo starting import of GAF data

{
    (
        cd $SOURCES/pombe-embl/external_data/external-go-data
for gaf_file in go_comp.txt go_proc.txt go_func.txt From_curation_tool GO_ORFeome_localizations2.txt GO-0070647_gap_filling.gaf.txt GO-0023052_gap_filling.gaf.txt PMID_*_gaf.tsv
do
  echo reading $gaf_file
  $POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml gaf --assigned-by-filter=PomBase "$HOST" $DB $USER $PASSWORD < $gaf_file

  echo counts:
  evidence_summary $DB
done

   )

echo Updating $SOURCES/gene_association.pombase.inf.gaf

GET 'http://build.berkeleybop.org/job/gaf-check-pombase/lastSuccessfulBuild/artifact/gene_association.pombase.inf.gaf' | perl -ne 'print unless /\tC\t/' > $SOURCES/gene_association.pombase.inf.gaf.new || echo failed to download gene_association.pombase.inf.gaf
if [ -s $SOURCES/gene_association.pombase.inf.gaf.new ]
then
  mv $SOURCES/gene_association.pombase.inf.gaf $SOURCES/gene_association.pombase.inf.gaf.old
  mv $SOURCES/gene_association.pombase.inf.gaf.new $SOURCES/gene_association.pombase.inf.gaf
else
  echo "Coudn't download new gene_association.pombase.inf.gaf - file is empty" 1>&2
fi

$POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings --assigned-by-filter=PomBase,GOC "$HOST" $DB $USER $PASSWORD < $SOURCES/gene_association.pombase.inf.gaf

echo counts after loading gene_association.pombase.inf.gaf:
evidence_summary $DB

echo reading $SOURCES/gene_association.goa_uniprot.pombe
CURRENT_GOA_GAF="$SOURCES/gene_association.goa_uniprot.gz"
DOWNLOADED_GOA_GAF=$CURRENT_GOA_GAF.downloaded

if GET -i $CURRENT_GOA_GAF $GOA_GAF_URL > $DOWNLOADED_GOA_GAF
then
  mv $DOWNLOADED_GOA_GAF $CURRENT_GOA_GAF
else
  echo "didn't download new $GOA_GAF_URL"
fi

gzip -d < $CURRENT_GOA_GAF | perl -ne 'print if /\ttaxon:(4896|284812)\t/' | $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --use-only-first-with-id --taxon-filter=4896 --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings --assigned-by-filter=InterPro,UniProtKB,UniProt "$HOST" $DB $USER $PASSWORD

} 2>&1 | tee $LOG_DIR/$log_file.gaf-load-output

echo annotation count after GAF loading:
evidence_summary $DB


echo load quantitative gene expression data

for file in $SOURCES/pombe-embl/external_data/Quantitative_gene_expression_data/*
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml quantitative --organism_taxonid=4896 "$HOST" $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.quantitative


echo load bulk protein modification files

for file in $SOURCES/pombe-embl/external_data/modification_files/PMID*
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml modification "$HOST" $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.modification


echo load bulk qualitative gene expression files

for file in $SOURCES/pombe-embl/external_data/qualitative_gene_expression_data/*
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml qualitative --gene-ex-qualifiers=$SOURCES/pombe-embl/supporting_files/gene_ex_qualifiers "$HOST" $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.qualitative


echo phenotype data from PMID:23697806
$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml phenotype-annotation "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/phenotype_mapping/phaf_format_phenotypes.tsv 2>&1 | tee $LOG_DIR/$log_file.phenotypes_from_PMID_23697806-phenotype_mapping

for i in $SOURCES/pombe-embl/external_data/phaf_files/chado_load/PMID_*.*[^~]
do
  f=`basename $i .tsv`
  echo loading phenotype data from $f
  ($POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml phenotype-annotation "$HOST" $DB $USER $PASSWORD < $i) 2>&1 | tee -a $LOG_DIR/$log_file.phenotypes_from_$f
done

echo load Compara orthologs

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=PMID:19029536 --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/compara_orths.tsv 2>&1 | tee $LOG_DIR/$log_file.compara_orths


echo load manual pombe to human orthologs: conserved_multi.txt

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=null --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/conserved_multi.txt 2>&1 | tee $LOG_DIR/$log_file.manual_multi_orths

echo load manual pombe to human orthologs: conserved_one_to_one.txt

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=null --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction --add_org_1_term_name='predominantly single copy (one to one)' --add_org_1_term_cv='species_dist' "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/conserved_one_to_one.txt 2>&1 | tee $LOG_DIR/$log_file.manual_1-1_orths

CURATION_TOOL_DATA=/var/pomcur/backups/current-prod-dump.json

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml canto-json --organism-taxonid=4896 --db-prefix=PomBase "$HOST" $DB $USER $PASSWORD < $CURATION_TOOL_DATA 2>&1 | tee $LOG_DIR/$log_file.curation_tool_data

echo annotation count after loading curation tool data:
evidence_summary $DB

$POMBASE_CHADO/script/pombase-process.pl load-pombase-chado.yaml add-reciprocal-ipi-annotations  --organism-taxonid=4896 "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.add_reciprocal_ipi_annotations

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'
refresh_views

echo filtering redundant annotations - `date`
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml go-filter "$HOST" $DB $USER $PASSWORD
echo done filtering - `date`

echo annotation count after filtering redundant GO annotations
evidence_summary $DB

echo update out of date allele names
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml update-allele-names "$HOST" $DB $USER $PASSWORD

echo change UniProtKB IDs in "with" feature_cvterprop rows to PomBase IDs
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml uniprot-ids-to-local "$HOST" $DB $USER $PASSWORD

echo do GO term re-mapping
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml change-terms \
  --exclude-by-fc-prop="canto_session" \
  --mapping-file=$SOURCES/pombe-embl/chado_load_mappings/GO_mapping_to_specific_terms.txt \
  "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.go-term-mapping

echo query PubMed for publication details, then store
$POMBASE_CHADO/script/pubmed_util.pl ./load-pombase-chado.yaml \
  "$HOST" $DB $USER $PASSWORD --add-missing-fields 2>&1 | tee $LOG_DIR/$log_file.pubmed_query

PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'
refresh_views

echo annotation count after filtering redundant annotations:
evidence_summary $DB

echo running consistency checks
if $POMBASE_CHADO/script/check-chado.pl ./load-pombase-chado.yaml "$HOST" $DB $USER $PASSWORD > $LOG_DIR/$log_file.chado_checks 2>&1
then
    CHADO_CHECKS_STATUS=passed
else
    CHADO_CHECKS_STATUS=failed
fi

POMBASE_EXCLUDED_GO_TERMS_SOFTCHECK=$SOURCES/pombe-embl/supporting_files/GO_terms_excluded_from_pombase.txt
echo report annotations using GO terms from $POMBASE_EXCLUDED_GO_TERMS_SOFTCHECK 2>&1 | tee $LOG_DIR/$log_file.excluded_go_terms_softcheck
./script/report-subset.pl "$HOST" $DB $USER $PASSWORD $POMBASE_EXCLUDED_GO_TERMS_SOFTCHECK 2>&1 | tee -a $LOG_DIR/$log_file.excluded_go_terms_softcheck

POMBASE_EXCLUDED_FYPO_TERMS_SOFTCHECK=$SOURCES/pombe-embl/supporting_files/FYPO_terms_excluded_from_pombase.txt
echo report annotations using FYPO terms from $POMBASE_EXCLUDED_FYPO_TERMS_SOFTCHECK 2>&1 | tee $LOG_DIR/$log_file.excluded_fypo_terms_softcheck
./script/report-subset.pl "$HOST" $DB $USER $PASSWORD $POMBASE_EXCLUDED_FYPO_TERMS_SOFTCHECK 2>&1 | tee -a $LOG_DIR/$log_file.excluded_fypo_terms_softcheck

POMBASE_EXCLUDED_FYPO_TERMS_OBO=$SOURCES/pombe-embl/mini-ontologies/FYPO_qc_do_not_annotate_subsets.obo
echo report annotations using FYPO terms from $POMBASE_EXCLUDED_FYPO_TERMS_OBO 2>&1 | tee $LOG_DIR/$log_file.excluded_fypo_terms
./script/report-subset.pl "$HOST" $DB $USER $PASSWORD <(perl -ne 'print "$1\n" if /^id:\s*(FYPO:\S+)/' $POMBASE_EXCLUDED_FYPO_TERMS_OBO) 2>&1 | tee -a $LOG_DIR/$log_file.excluded_fypo_terms

DUMPS_DIR=/var/www/pombase/dumps
BUILDS_DIR=$DUMPS_DIR/builds
CURRENT_BUILD_DIR=$BUILDS_DIR/$DB

mkdir $CURRENT_BUILD_DIR
mkdir $CURRENT_BUILD_DIR/logs
mkdir $CURRENT_BUILD_DIR/exports

(
echo starting gaf export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml gaf --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.gaf.gz
echo starting go-physical-interactions export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml go-physical-interactions --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombase-go-physical-interactions.tsv.gz
echo starting go-substrates export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml go-substrates --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombase-go-substrates.tsv.gz
echo starting interactions export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml interactions --since-date=$PREV_DATE --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombase-interactions-since-$PREV_VERSION-$PREV_DATE.gz
echo starting orthologs export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml orthologs --organism-taxon-id=4896 --other-organism-taxon-id=9606 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.human-orthologs.txt.gz
echo starting phaf export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml phaf --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.phaf.gz
echo starting modifications export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml modifications --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.modifications.gz
echo starting publications with annotations export at `date`
psql $DB -t --no-align -c "
SELECT uniquename FROM pub WHERE uniquename LIKE 'PMID:%'
   AND pub_id IN (SELECT pub_id FROM feature_cvterm UNION SELECT pub_id FROM feature_relationship_pub)
 ORDER BY substring(uniquename FROM 'PMID:(\d+)')::integer;" > $CURRENT_BUILD_DIR/publications_with_annotations.txt
) > $LOG_DIR/$log_file.export_warnings 2>&1

gzip -d < $CURRENT_BUILD_DIR/$DB.gaf.gz | /var/pomcur/sources/go-svn/software/utilities/filter-gene-association.pl -e > $LOG_DIR/$log_file.gaf-check

cp $LOG_DIR/$log_file.gaf-load-output $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.biogrid-load-output $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.gaf-check $CURRENT_BUILD_DIR/logs/$log_file.gaf-check
cp $LOG_DIR/$log_file.compara_orths $CURRENT_BUILD_DIR/logs/$log_file.compara-orth-load-output
cp $LOG_DIR/$log_file.manual_multi_orths $CURRENT_BUILD_DIR/logs/$log_file.manual-multi-orths-output
cp $LOG_DIR/$log_file.manual_1-1_orths $CURRENT_BUILD_DIR/logs/$log_file.manual-1-1-orths-output
cp $LOG_DIR/$log_file.add_reciprocal_ipi_annotations $CURRENT_BUILD_DIR/logs/$log_file.add_reciprocal_ipi_annotations
cp $LOG_DIR/$log_file.curation_tool_data $CURRENT_BUILD_DIR/logs/$log_file.curation-tool-data-load-output
cp $LOG_DIR/$log_file.quantitative $CURRENT_BUILD_DIR/logs/$log_file.quantitative
cp $LOG_DIR/$log_file.qualitative $CURRENT_BUILD_DIR/logs/$log_file.qualitative
cp $LOG_DIR/$log_file.modification $CURRENT_BUILD_DIR/logs/$log_file.modification
cp $LOG_DIR/$log_file.*phenotypes_from_* $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.export_warnings $CURRENT_BUILD_DIR/logs/$log_file.export_warnings
cp $LOG_DIR/$log_file.excluded_go_terms_softcheck $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.excluded_fypo_terms_softcheck $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.excluded_fypo_terms $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.go-term-mapping $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.chado_checks $CURRENT_BUILD_DIR/logs/

refresh_views

(
echo extension relation counts:
psql $DB -c "select count(id), name, base_cv_name from (select p.cvterm_id::text || '_cvterm' as id,
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

psql $DB -c "select count(feature_cvterm_id), base_cv_name from pombase_feature_cvterm_with_ext_parents group by base_cv_name order by count;"
) > $CURRENT_BUILD_DIR/logs/$log_file.extension_relation_counts

(
echo counts of qualifiers grouped by CV name
psql $DB -c "select count(fc.feature_cvterm_id), value, base_cv_name from feature_cvtermprop p, pombase_feature_cvterm_ext_resolved_terms fc, cvterm t where type_id = (select cvterm_id from cvterm where name = 'qualifier' and cv_id = (select cv_id from cv where name = 'feature_cvtermprop_type')) and p.feature_cvterm_id = fc.feature_cvterm_id and fc.cvterm_id = t.cvterm_id group by value, base_cv_name order by count desc;"
) > $CURRENT_BUILD_DIR/logs/$log_file.qualifier_counts_by_cv

(
echo all protein family term and annotated genes
psql $DB -c "select t.name, db.name || ':' || x.accession as termid, array_to_string(array_agg(f.uniquename), ',') as gene_uniquenames from feature f join feature_cvterm fc on fc.feature_id = f.feature_id join cvterm t on t.cvterm_id = fc.cvterm_id join dbxref x on x.dbxref_id = t.dbxref_id join db on x.db_id = db.db_id join cv on t.cv_id = cv.cv_id where cv.name = 'PomBase family or domain' group by t.name, termid order by t.name, termid;"
) > $CURRENT_BUILD_DIR/logs/$log_file.protein_family_term_annotation

(
echo 'Alleles with type "other"'
psql $DB -F ',' -A -c "select f.name, f.uniquename, (select value from featureprop p where
p.feature_id = f.feature_id and p.type_id in (select cvterm_id from cvterm
where name = 'description')) as description, (select value from featureprop p where
p.feature_id = f.feature_id and p.type_id in (select cvterm_id from cvterm
where name = 'canto_session')) as session from feature f where type_id in (select
cvterm_id from cvterm where name = 'allele') and feature_id in (select
feature_id from featureprop p where p.type_id in (select cvterm_id from cvterm
where name = 'allele_type') and p.value = 'other');"
) > $CURRENT_BUILD_DIR/logs/$log_file.alleles_of_type_other

(
echo counts of all annotation by type:
psql $DB -c "select count(distinct fc_id), cv_name from (select distinct
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
psql $DB -c "with sub as (select distinct
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
psql $DB -c "with sub as (select distinct
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
psql $DB -c "with sub as (select distinct
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
psql $DB -c "select count(distinct fc_id) from (select distinct
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
psql $DB -c "select count(distinct fc_id), cv_name from $sub_query group by cv_name order by count;"
psql $DB -c "select count(distinct fc_id) as total from $sub_query;"

 ) > $CURRENT_BUILD_DIR/logs/$log_file.annotation_counts_by_cv

refresh_views

$POMCUR/bin/pombase-chado-json -c $SOURCES/pombe-embl/website/pombase_v2_config.json -p "postgres://kmr44:kmr44@localhost/$DB" -d $CURRENT_BUILD_DIR/  -i /var/pomcur/sources/interpro/pombe_domain_results.json 2>&1 | tee $LOG_DIR/$log_file.web-json-write

gzip -r9 $CURRENT_BUILD_DIR/fasta

cp $LOG_DIR/$log_file.web-json-write $CURRENT_BUILD_DIR/logs/

DB_BASE_NAME=`echo $DB | sed 's/-v[0-9]$//'`

cp -r $SOURCES/current_build_files/$DB_BASE_NAME/* $CURRENT_BUILD_DIR/


cp $LOG_DIR/*.txt $CURRENT_BUILD_DIR/logs/

mkdir $CURRENT_BUILD_DIR/pombe-embl
(
  cd $SOURCES/pombe-embl
  cp -r website *.contig external_data mini-ontologies \
    supporting_files orthologs \
    $CURRENT_BUILD_DIR/pombe-embl/
)

psql $DB -c 'grant select on all tables in schema public to public;'

DUMP_FILE=$CURRENT_BUILD_DIR/$DB.dump.gz

echo dumping to $DUMP_FILE
pg_dump $DB | gzip -9 > $DUMP_FILE

rm -f $DUMPS_DIR/latest_build
ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/latest_build

(cd ~/git/pombase-chado && nice -10 ./etc/build_container.sh $DB_DATE_VERSION $DUMPS_DIR/latest_build prod)
docker service update --image=pombase/web:$DB_DATE_VERSION-prod pombase-dev

if [ $CHADO_CHECKS_STATUS=passed ]
then
    rm -f $DUMPS_DIR/nightly_update
    ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/nightly_update

    nice -19 docker save pombase/web:$DB_DATE_VERSION-prod | ssh pombase-admin@149.155.131.177 sudo docker load
    echo copied pombase/web:$DB_DATE_VERSION-prod to the server

    rsync --delete-after -aHS $CURRENT_BUILD_DIR/ pombase-admin@149.155.131.177:/home/ftp/pombase/nightly_update/

    rsync --delete-after -aHS $SOURCES/pombe-embl/ftp_site/pombe/ pombase-admin@149.155.131.177:/home/ftp/pombase/pombe/
fi

date
