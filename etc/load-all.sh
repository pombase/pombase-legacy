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

PATH=$PATH:/usr/local/bin

DATE_VERSION=$DATE

die() {
  echo $1 1>&2
  exit 1
}

POMCUR=/var/pomcur
WWW_DIR=/var/www/pombase
DUMPS_DIR=$WWW_DIR/dumps
POMCUR_LATEST_BUILD=$DUMPS_DIR/latest_build/
SOURCES=$POMCUR/sources

POMBASE_WEB_CONFIG=$HOME/git/pombase-config/website/pombase_v2_config.json

# without a user agent we get "bad gateway" from ftp.ebi.ac.uk
USER_AGENT_FOR_EBI='Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US; rv:1.8.1.13) Gecko/20080311 Firefox/2.0.0.13'

(cd ~/chobo/; git pull) || die "Failed to update Chobo"
(cd ~/git/pombase-config; git pull) || die "Failed to update pombase-config"
(cd ~/git/pombase-chado; git pull) || die "Failed to update pombase-chado"
(cd ~/git/pombase-legacy; git pull) || die "Failed to update pombase-legacy"
(cd ~/git/pombase-website; git pull) || die "Failed to update pombase-website"
(cd ~/git/genome_changelog; git pull) || die "Failed to update genome_changelog"
(cd ~/git/japonicus-curation; git pull) || die "Failed to update japonicus-curation"

(cd $SOURCES/pombe-embl/; svn update || exit 1)

(cd $SOURCES/go-site/; git pull || exit 1)

. $SOURCES/private-config/pombase_load_secrets

docker service update --replicas 0 pombase-dev

(cd ~/git/pombase-legacy
 export PATH=$HOME/chobo/script/:/usr/local/owltools-v0.3.0-74-gee0f8bbd/OWLTools-Runner/bin/:$PATH
 export CHADO_CLOSURE_TOOL=$HOME/git/pombase-chado/script/relation-graph-chado-closure.pl
 export PERL5LIB=$HOME/git/pombase-chado:$HOME/chobo/lib/
 time nice -19 ./script/make-db $DATE "$HOST" $USER $PASSWORD) || die "make-db failed"

DB=pombase-build-$DATE_VERSION

LOG_DIR=`pwd`

POMBASE_CHADO=$HOME/git/pombase-chado
POMBASE_LEGACY=$HOME/git/pombase-legacy
JAPONICUS_CURATION=$HOME/git/japonicus-curation

JAPONICUS_BUILD_DIR=$WWW_DIR/japonicus_nightly/latest_build


LOAD_CONFIG=$POMBASE_LEGACY/load-pombase-chado.yaml

GOA_GAF_URL=https://ftp.ebi.ac.uk/pub/databases/GO/goa/UNIPROT/goa_uniprot_all.gaf.gz

cd $POMBASE_CHADO
git pull || exit 1

cd $POMBASE_LEGACY
git pull || exit 1

export PERL5LIB=$HOME/git/pombase-chado/lib:$POMBASE_LEGACY/lib

echo initialising Chado with CVs and cvterms
$POMBASE_CHADO/script/pombase-admin.pl $POMBASE_LEGACY/load-pombase-chado.yaml chado-init \
  "$HOST" $DB $USER $PASSWORD || exit 1


(cd $SOURCES
wget -q -N https://ftp.ebi.ac.uk/pub/databases/genenames/new/tsv/hgnc_complete_set.txt ||
    echo failed to download new HGNC data
wget -q -N http://downloads.yeastgenome.org/curation/chromosomal_feature/SGD_features.tab ||
    echo failed to download new SGD data
)

echo loading organisms
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml organisms \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/pombase_organism_config.tsv

echo loading PB refs
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml references-file \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/PB_references.txt

echo loading GO refs parsed from go-site/metadata/gorefs/
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml references-file \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/go_references.txt


echo loading human genes
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
    --organism-taxonid=9606 --uniquename-column=1 --name-column=2 --feature-type=gene \
    --product-column=3 --transcript-so-name=transcript \
    --ignore-lines-matching="^hgnc_id.symbol" --ignore-short-lines \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/hgnc_complete_set.txt


# create the input file with:
# (cd git/pombase-legacy/; ./etc/query_yeastmine_genes.py > /var/pomcur/sources/sgd_yeastmine_genes.tsv)

echo loading protein coding genes from SGD data file
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
    --organism-taxonid=4932 --uniquename-column=5 --name-column=6 \
    --product-column=4 \
    --column-filter="1=ORF,blocked_reading_frame,blocked reading frame,not in systematic sequence of S288C" --feature-type=gene \
    --transcript-so-name=transcript \
    --feature-prop-from-column=sgd_identifier:3 \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/sgd_yeastmine_genes.tsv

for so_type in ncRNA snoRNA
do
  echo loading $so_type genes from SGD data file
  $POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
      --organism-taxonid=4932 --uniquename-column=5 --name-column=6 \
      --column-filter="1=${so_type} gene" --feature-type=gene \
      "$HOST" $DB $USER $PASSWORD < $SOURCES/sgd_yeastmine_genes.tsv
done


echo loading japonicus genes

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG features \
    --organism-taxonid=4897 --uniquename-column=1 --name-column=3 --feature-type=gene \
    --product-column=5 --ignore-short-lines \
    --transcript-so-name=mRNA --column-filter="7=protein coding gene" \
    "$HOST" $DB $USER $PASSWORD < $JAPONICUS_BUILD_DIR/misc/gene_IDs_names_products.tsv

for so_type in ncRNA tRNA snoRNA rRNA snRNA
do
  $POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG features \
      --organism-taxonid=4897 --uniquename-column=1 --name-column=3 \
      --product-column=5 --ignore-short-lines \
      --transcript-so-name=$so_type \
      --column-filter="7=${so_type} gene" --feature-type=gene \
     "$HOST" $DB $USER $PASSWORD < $JAPONICUS_BUILD_DIR/misc/gene_IDs_names_products.tsv
done


cd $LOG_DIR
log_file=log.`date +'%Y-%m-%d-%H-%M-%S'`
echo loading contigs with load-chado.pl, log file: $log_file
date

`dirname $0`/../script/load-chado.pl --taxonid=4896 \
  --mapping "sequence_feature:sequence:$SOURCES/pombe-embl/chado_load_mappings/features-to-so_mapping_only.txt" \
  --mapping "pt_mod:PSI-MOD:$SOURCES/pombe-embl/chado_load_mappings/modification_map.txt" \
  --mapping "phenotype:fission_yeast_phenotype:$SOURCES/pombe-embl/chado_load_mappings/phenotype-map.txt" \
  --mapping "disease_associated:mondo:$SOURCES/pombe-embl/chado_load_mappings/disease_name_to_MONDO_mapping.txt:PB_REF:0000003" \
  --gene-ex-qualifiers $SOURCES/pombe-embl/supporting_files/gene_ex_qualifiers \
  --obsolete-term-map $SOURCES/go-svn/doc/obsoletes-exact $POMBASE_LEGACY/load-pombase-chado.yaml \
  $DATE_VERSION "$HOST" $DB $USER $PASSWORD $SOURCES/pombe-embl/*.contig 2>&1 | tee $log_file || exit 1

$POMBASE_LEGACY/etc/process-log.pl $log_file

pg_dump $DB | gzip -5 > /tmp/pombase-chado-after-load-chado-pl.dump.gz


## Disabled temporarily because of: https://github.com/pombase/pombase-chado/issues/992
#
#echo loading alleles from previous load
#date
#ALLELE_SUMMARIES=$POMCUR_LATEST_BUILD/misc/allele_summaries.json
#$POMCUR/bin/pombase-chado-load -p "postgres://kmr44:kmr44@localhost/$DB" \
#  --taxonid 4896 allele-json $ALLELE_SUMMARIES


# See: https://github.com/pombase/pombase-chado/issues/861
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml gaf \
    --load-qualifiers --load-column-17 \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/legacy_go_annotations_from_contigs.gaf.tsv \
    > $log_file.legacy_go_from_contigs 2>&1

# See: https://github.com/pombase/pombase-chado/issues/948
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml phenotype-annotation \
    --throughput-type='low throughput' \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/legacy_phenotype_annotations_from_contigs.phaf.tsv \
    > $log_file.legacy_phaf_from_contigs 2>&1


echo loading features without coordinates
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml features \
    --organism-taxonid=4896 --uniquename-column=1 --name-column=2 --feature-type=promoter \
    --reference-column=6 --date-column=7 \
    --parent-feature-id-column=5 --parent-feature-rel-column=4 \
    --ignore-lines-matching="^Identifier" \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/features_without_coordinates.txt

echo starting import of biogrid data | tee $log_file.biogrid-load-output

(cd $SOURCES/biogrid
 wget -q -N https://downloads.thebiogrid.org/Download/BioGRID/Latest-Release/BIOGRID-ORGANISM-LATEST.tab2.zip) || { echo "failed to download new BioGRID data" 1>&2; exit 1; }

(cd $SOURCES/biogrid
rm -f $SOURCES/biogrid/BIOGRID-ORGANISM-*.tab2.txt

unzip -qo BIOGRID-ORGANISM-LATEST.tab2.zip
if [ ! -e BIOGRID-ORGANISM-Schizosaccharomyces_pombe*.tab2.txt ]
then
  echo "no pombe BioGRID file found - exiting"
  exit 1
fi
) 2>&1 | tee -a $log_file.biogrid-load-output

cd $POMBASE_LEGACY

# see https://sourceforge.net/p/pombase/chado/61/
cat $SOURCES/biogrid/BIOGRID-ORGANISM-Schizosaccharomyces_pombe*.tab2.txt |
  $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml biogrid \
     --use_first_with_id --source-database-filter=PomBase \
     --organism-taxonid-filter=284812:4896 \
     --interaction-note-filter="triple mutant" \
     --evidence-code-filter='Co-localization' "$HOST" $DB $USER $PASSWORD 2>&1 |
  tee -a $LOG_DIR/$log_file.biogrid-load-output


INTERACTIONS_DIR=$SOURCES/pombe-embl/external_data/interactions

for i in $INTERACTIONS_DIR/*.tab2.txt
do
    # PomBase curated interactions

    if [ $i = "$INTERACTIONS_DIR/PMID_19111658_interactions.tab2.txt" ]
    then
        file_date=2018-09-21
    else
        if [ $i = "$INTERACTIONS_DIR/PMID_25795664_scored_interactions.tab2.txt" ]
        then
            file_date=2016-08-05
        else
            file_date=`stat -c %y $i | awk '{printf $1 "\n"}'`
        fi
    fi

    $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml biogrid --organism-taxonid-filter=284812:4896 \
       --annotation-date=$file_date \
       "$HOST" $DB $USER $PASSWORD < $i 2>&1 | tee -a $LOG_DIR/$log_file.pombase-curated-interactions
done


evidence_summary () {
  DB=$1
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'evidence') group by value order by count(feature_cvtermprop_id)" | cat
}

assigned_by_summary () {
  DB=$1
  psql $DB -c "select count(feature_cvtermprop_id), value from feature_cvtermprop where type_id in (select cvterm_id from cvterm where name = 'assigned_by') group by value order by count(feature_cvtermprop_id);" | cat
}

refresh_views () {
  PGPASSWORD=$PASSWORD psql -U $USER -h "$HOST" $DB -c 'analyze'

  for view in \
    pombase_annotated_gene_features_per_publication \
    pombase_feature_cvterm_with_ext_parents \
    pombase_feature_cvterm_no_ext_terms \
    pombase_feature_cvterm_ext_resolved_terms \
    pombase_genotypes_alleles_genes_mrna \
    pombase_extension_rels_and_values \
    pombase_genes_annotations_dates \
    pombase_annotation_summary \
    pombase_publication_curation_summary
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
for gaf_file in go_comp.txt go_proc.txt go_func.txt From_curation_tool GO_ORFeome_localizations2.txt GO-0023052_gap_filling.gaf.txt PMID_*_gaf.tsv
do
  echo reading $gaf_file

  $POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml gaf --ignore-synonyms "$HOST" $DB $USER $PASSWORD < $gaf_file

  echo counts:
  evidence_summary $DB
done

   )

echo Updating $SOURCES/pombase-prediction.gaf

POMBASE_PREDICTION_URL=http://snapshot.geneontology.org/products/upstream_and_raw_data/pombase-prediction.gaf

GET $POMBASE_PREDICTION_URL | perl -ne 'print unless /\tC\t/' > $SOURCES/pombase-prediction.gaf.new || echo failed to download pombase-prediction.gaf

if [ -s $SOURCES/pombase-prediction.gaf.new ]
then
  if grep -q 'gaf-version: 2.0' $SOURCES/pombase-prediction.gaf.new
  then
    mv $SOURCES/pombase-prediction.gaf $SOURCES/pombase-prediction.gaf.old
    mv $SOURCES/pombase-prediction.gaf.new $SOURCES/pombase-prediction.gaf
  else
    echo "Failed to download new pombase-prediction.gaf - doesn't look like a GAF file" 1>&2
  fi
else
  echo "Coudn't download new pombase-prediction.gaf - file is empty" 1>&2
fi

# load GO annotation inferred inter ontology links
$POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings --assigned-by-filter=PomBase,GOC "$HOST" $DB $USER $PASSWORD < $SOURCES/pombase-prediction.gaf

echo counts after loading pombase-prediction.gaf:
evidence_summary $DB

pg_dump $DB | gzip -5 > /tmp/pombase-chado-before-goa.dump.gz


GOA_GAF_FILENAME=gene_association.goa_uniprot.gz
CURRENT_GOA_GAF="$SOURCES/$GOA_GAF_FILENAME"

echo checking for new GOA GAF file
curl --user-agent "$USER_AGENT_FOR_EBI" -o $CURRENT_GOA_GAF -z $CURRENT_GOA_GAF $GOA_GAF_URL ||
  echo failed to download new $CURRENT_GOA_GAF, continuing with previous version

echo reading $CURRENT_GOA_GAF

gzip -d < $CURRENT_GOA_GAF | perl -ne 'print if /\ttaxon:(4896|284812)\t/' | $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --use-only-first-with-id --taxon-filter=4896 --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings --assigned-by-filter=InterPro,UniProtKB,UniProt,RHEA,IntAct,RNAcentral,ComplexPortal,CAFA "$HOST" $DB $USER $PASSWORD

pg_dump $DB | gzip -5 > /tmp/pombase-chado-after-goa.dump.gz


(cd $SOURCES/snapshot.geneontology.org && wget -N http://snapshot.geneontology.org/annotations/pombase.gaf.gz)

# echo loading PANTHER annotation - don't load this from GOA because GOA updates slowly
gzip -d < $SOURCES/snapshot.geneontology.org/pombase.gaf.gz | $POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml gaf --term-id-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_GO_IDs --with-filter-filename=$SOURCES/pombe-embl/goa-load-fixes/filtered_mappings --with-prefix-filter="PANTHER:" --taxon-filter=4896 --assigned-by-filter=GO_Central "$HOST" $DB $USER $PASSWORD

} 2>&1 | tee $LOG_DIR/$log_file.gaf-load-output

echo annotation count after GAF loading:
evidence_summary $DB


echo load pombe KEGG data

TEMP_KEGG=/tmp/temp_egg.$$.tsv

if GET http://rest.kegg.jp/link/pathway/spo > $TEMP_KEGG
then
    if [ -s $TEMP_KEGG ]
    then
        cp $TEMP_KEGG $SOURCES/pombe_kegg_latest.tsv
    else
        echo failed to fetch KEGG data, empty result 1>&2
    fi
else
    echo failed to fetch KEGG data, error code: $? 1>&2
fi


perl -pne 's/^\s*spo:(\S+)\s+path:(\S+)\s*/$1\t\tKEGG_PW:$2\t\tPMID:10592173\t'$DATE_VERSION'\n/' $SOURCES/pombe_kegg_latest.tsv |
  $POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml generic-annotation \
    --organism-taxonid=4896 "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.kegg-pathway


echo load RNAcentral pombe identifiers
curl --user-agent "$USER_AGENT_FOR_EBI" -s -o $SOURCES/rnacentral_pombe_identifiers.tsv -z $SOURCES/rnacentral_pombe_identifiers.tsv https://ftp.ebi.ac.uk/pub/databases/RNAcentral/current_release/id_mapping/database_mappings/pombase.tsv ||
  echo failed to download new RNAcentral identifier file, continuing with previous version

$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml generic-property \
    --property-name="rnacentral_identifier" --organism-taxonid=4896 \
    --feature-uniquename-column=6 --property-column=1 \
    "$HOST" $DB $USER $PASSWORD < $SOURCES/rnacentral_pombe_identifiers.tsv

echo load PDBe IDs

perl -ne '
    ($id, $pdb_id, $taxon_id) = split /\t/;
    print "$id\t$pdb_id\n" if $taxon_id == 4896;
  ' < $SOURCES/pombe-embl/external_data/protein_structure/systematic_id_to_pdbe_mapping.tsv |
    sort | uniq |
$POMBASE_CHADO/script/pombase-import.pl $POMBASE_LEGACY/load-pombase-chado.yaml generic-property \
    --property-name="pdb_identifier" --organism-taxonid=4896 \
    --feature-uniquename-column=1 --property-column=2 \
    "$HOST" $DB $USER $PASSWORD


echo update RNAcentral data file
curl --user-agent "$USER_AGENT_FOR_EBI" -s -o $SOURCES/rfam_annotations.tsv.gz -z $SOURCES/rfam_annotations.tsv.gz https://ftp.ebi.ac.uk/pub/databases/RNAcentral/current_release/rfam/rfam_annotations.tsv.gz ||
  echo failed to download new RNAcentral annotations file, continuing with previous version

echo load quantitative gene expression data

for file in $SOURCES/pombe-embl/external_data/Quantitative_gene_expression_data/*.txt
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml quantitative --organism_taxonid=4896 "$HOST" $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.quantitative


echo load bulk protein modification files

for file in $SOURCES/pombe-embl/external_data/modification_files/PMID*[^~]
do
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml modification "$HOST" $DB $USER $PASSWORD < $file > /tmp/log.modification.tmp.txt 2>&1

  if [ -s /tmp/log.modification.tmp.txt ]
  then
      echo loading: $file
      cat /tmp/log.modification.tmp.txt
  fi
done | tee $LOG_DIR/$log_file.modification


echo load bulk qualitative gene expression files

for file in $SOURCES/pombe-embl/external_data/qualitative_gene_expression_data/*.txt
do
  echo loading: $file
  $POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml qualitative --gene-ex-qualifiers=$SOURCES/pombe-embl/supporting_files/gene_ex_qualifiers "$HOST" $DB $USER $PASSWORD < $file 2>&1
done | tee $LOG_DIR/$log_file.qualitative


for i in $SOURCES/pombe-embl/external_data/phaf_files/chado_load/htp_phafs/PMID_*.*[^~]
do
  f=`basename $i .tsv`
  echo loading HTP phenotype data from $f
  ($POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml phenotype-annotation --throughput-type='high throughput' "$HOST" $DB $USER $PASSWORD < $i) 2>&1 | tee -a $LOG_DIR/$log_file.phenotypes_from_$f
done

for i in $SOURCES/pombe-embl/external_data/phaf_files/chado_load/ltp_phafs/PMID_*.*[^~]
do
  f=`basename $i .tsv`
  echo loading LTP phenotype data from $f
  ($POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml phenotype-annotation --throughput-type='low throughput' "$HOST" $DB $USER $PASSWORD < $i) 2>&1 | tee -a $LOG_DIR/$log_file.phenotypes_from_$f
done

echo load Compara orthologs

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=PMID:19029536 --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/compara_orths.tsv 2>&1 | tee $LOG_DIR/$log_file.compara_orths


echo
echo load manual pombe to human orthologs: conserved_multi.txt

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=null --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/conserved_multi.txt 2>&1 | tee $LOG_DIR/$log_file.manual_multi_orths

echo
echo load manual pombe to human orthologs: conserved_one_to_one.txt

$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml orthologs --publication=null --organism_1_taxonid=4896 --organism_2_taxonid=9606 --swap-direction --add_org_1_term_name='predominantly single copy (one to one)' --add_org_1_term_cv='species_dist' "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/orthologs/conserved_one_to_one.txt 2>&1 | tee $LOG_DIR/$log_file.manual_1-1_orths


echo
echo load Compara pombe-japonicus orthologs

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --swap-direction --publication=PMID:26896847 --organism_1_taxonid=4897 --organism_2_taxonid=4896 \
  "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/compara_pombe_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.compara_pombe_japonicus_orthologs

echo load Rhind pombe-japonicus orthologs

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --swap-direction --publication=PMID:21511999 --organism_1_taxonid=4897 --organism_2_taxonid=4896 \
  "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/rhind_pombe_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.rhind_pombe_japonicus_orthologs

echo load manual pombe-japonicus orthologs

$POMBASE_CHADO/script/pombase-import.pl $LOAD_CONFIG orthologs \
  --swap-direction --publication=null --organism_1_taxonid=4897 --organism_2_taxonid=4896 \
  "$HOST" $DB $USER $PASSWORD < $JAPONICUS_CURATION/manual_pombe_orthologs.tsv 2>&1 | tee $LOG_DIR/$log_file.manual_pombe_japonicus_orthologs


echo
echo load Malacard data from malacards_data_for_chado_mondo_ids.tsv
$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml malacards --destination-taxonid=4896 "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/external_data/disease/malacards_data_for_chado_mondo_ids.tsv 2>&1 | tee $LOG_DIR/$log_file.malacards_data

echo
echo load disease associations from pombase_disease_associations_mondo_ids.tsv
$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml generic-annotation --organism-taxonid=4896 "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/external_data/disease/pombase_disease_associations_mondo_ids.tsv 2>&1 | tee $LOG_DIR/$log_file.disease_associations


refresh_views

# run this before loading the Canto data because the Canto loader creates
# reciprocals automatically
# See: https://github.com/pombase/pombase-chado/issues/723
# and: https://github.com/pombase/pombase-chado/issues/788
$POMBASE_CHADO/script/pombase-process.pl load-pombase-chado.yaml add-reciprocal-ipi-annotations  --organism-taxonid=4896 "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.add_reciprocal_ipi_annotations


pg_dump $DB | gzip -5 > /tmp/pombase-chado-before-canto.dump.gz


CURATION_TOOL_DATA=/var/pomcur/backups/current-prod-dump.json

echo
echo load Canto data
$POMBASE_CHADO/script/pombase-import.pl load-pombase-chado.yaml canto-json --organism-taxonid=4896 --db-prefix=PomBase "$HOST" $DB $USER $PASSWORD < $CURATION_TOOL_DATA 2>&1 | tee $LOG_DIR/$log_file.curation_tool_data

echo annotation count after loading curation tool data:
evidence_summary $DB

pg_dump $DB | gzip -5 > /tmp/pombase-chado-after-canto.dump.gz


echo loading extra allele synonyms
$POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml \
   generic-synonym --feature-name-column=1 --synonym-column=2 \
   --publication-uniquename-column=3 \
  "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/allele_synonyms.txt \
   2>&1 | tee -a $LOG_DIR/$log_file.allele-synonyms-from-supporting-data


echo loading extra allele comments
$POMBASE_CHADO/script/pombase-import.pl ./load-pombase-chado.yaml \
   generic-property --feature-name-column=1 --property-name="comment" \
   --property-column=2 --organism-taxonid=4896 --reference-column=3 \
  "$HOST" $DB $USER $PASSWORD < $SOURCES/pombe-embl/supporting_files/allele_comments.txt \
   2>&1 | tee -a $LOG_DIR/$log_file.allele-comments-from-supporting-data


refresh_views

echo add ECO evidence codes
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml \
   add-eco-evidence-codes --eco-mapping-file=$SOURCES/pombe-embl/chado_load_mappings/ECO_evidence_mapping.txt \
   "$HOST" $DB $USER $PASSWORD

echo add missing allele names using the gene name and allele description
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml \
   add-missing-allele-names \
   "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.add-missing-allele-names

echo "fix allele names that don't have a gene name prefix"
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml fix-allele-names \
   "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.fix-allele-names

echo update out of date allele names
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml update-allele-names "$HOST" $DB $USER $PASSWORD

echo change UniProtKB IDs in "with" feature_cvterprop rows to PomBase IDs
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml uniprot-ids-to-local "$HOST" $DB $USER $PASSWORD

echo do GO term re-mapping
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml change-terms \
  --exclude-by-fc-prop="canto_session" \
  --mapping-file=$SOURCES/pombe-embl/chado_load_mappings/GO_mapping_to_specific_terms.txt \
  "$HOST" $DB $USER $PASSWORD 2>&1 | tee $LOG_DIR/$log_file.go-term-mapping


echo
echo counts of assigned_by before filtering:
assigned_by_summary $DB

$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml go-filter-duplicate-assigner \
   --primary-assigner=PomBase --secondary-assigner=UniProt \
   "$HOST" $DB $USER $PASSWORD > $LOG_DIR/$log_file.go-filter-uniprot-duplicates

$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml go-filter-duplicate-assigner \
   --primary-assigner=PomBase --secondary-assigner=IntAct \
   "$HOST" $DB $USER $PASSWORD > $LOG_DIR/$log_file.go-filter-intact-duplicates

pg_dump $DB | gzip -5 > /tmp/pombase-chado-before-go-filter.dump.gz

echo
echo filtering redundant annotations - `date`
$POMBASE_CHADO/script/pombase-process.pl ./load-pombase-chado.yaml go-filter "$HOST" $DB $USER $PASSWORD
echo done filtering - `date`

pg_dump $DB | gzip -5 > /tmp/pombase-chado-after-go-filter.dump.gz


echo
echo counts of assigned_by after filtering:
assigned_by_summary $DB

echo
echo annotation count after filtering redundant GO annotations
evidence_summary $DB

echo
echo query PubMed for publication details, then store
$POMBASE_CHADO/script/pubmed_util.pl ./load-pombase-chado.yaml \
  "$HOST" $DB $USER $PASSWORD --add-missing-fields 2>&1 | tee $LOG_DIR/$log_file.pubmed_query

refresh_views

echo
echo running QC queries from the config file
$POMBASE_CHADO/script/check-chado.pl ./load-pombase-chado.yaml qc_queries $POMBASE_WEB_CONFIG "$HOST" $DB $USER $PASSWORD $LOG_DIR/$log_file.qc_queries > $LOG_DIR/$log_file.qc_queries 2>&1


echo
echo running consistency checks
if $POMBASE_CHADO/script/check-chado.pl ./load-pombase-chado.yaml check_chado $POMBASE_WEB_CONFIG "$HOST" $DB $USER $PASSWORD $LOG_DIR/$log_file.chado_checks > $LOG_DIR/$log_file.chado_checks 2>&1
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

BUILDS_DIR=$DUMPS_DIR/builds
CURRENT_BUILD_DIR=$BUILDS_DIR/$DB

mkdir $CURRENT_BUILD_DIR
mkdir $CURRENT_BUILD_DIR/logs
mkdir $CURRENT_BUILD_DIR/exports

echo
echo export allele details
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml allele-details --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD > $CURRENT_BUILD_DIR/exports/all-allele-details.tsv


(

(
 cd $CURRENT_BUILD_DIR/
 ln -s $DB.gaf.gz pombase-latest.gaf.gz
 ln -s $DB.phaf.gz pombase-latest.phaf.gz
 ln -s $DB.eco.phaf.gz pombase-latest.eco.phaf.gz
 ln -s $DB.human-orthologs.txt.gz pombase-latest.human-orthologs.txt.gz
 ln -s $DB.cerevisiae-orthologs.txt.gz pombase-latest.cerevisiae-orthologs.txt.gz
 ln -s $DB.japonicus-orthologs.txt.gz pombase-latest.japonicus-orthologs.txt.gz
)

echo starting go-physical-interactions export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml go-physical-interactions --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombase-go-physical-interactions.tsv.gz
echo starting go-substrates export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml go-substrates --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombase-go-substrates.tsv.gz
echo starting interactions export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml interactions --since-date=$PREV_DATE --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombase-interactions-since-$PREV_VERSION-$PREV_DATE.gz

echo starting human orthologs export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml orthologs --organism-taxon-id=4896 --other-organism-taxon-id=9606 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.human-orthologs.txt.gz

echo starting cerevisiae ortholog export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml orthologs --organism-taxon-id=4896 --other-organism-field-name=uniquename --other-organism-taxon-id=4932 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.cerevisiae-orthologs.txt.gz

echo starting japonicus orthologs export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml orthologs --organism-taxon-id=4896  --other-organism-taxon-id=4897 --sensible-ortholog-direction --other-organism-field-name=uniquename "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.japonicus-orthologs.txt.gz

# export orthologs, one per line with uniquenames
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml simple-orthologs --swap-direction --organism-taxon-id=4896 --other-organism-taxon-id=9606 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombe-human-orthologs-with-systematic-ids.txt.gz

$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml simple-orthologs --swap-direction --organism-taxon-id=4896 --other-organism-taxon-id=4932 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombe-cerevisiae-orthologs-with-systematic-ids.txt.gz

$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml simple-orthologs --organism-taxon-id=4896 --other-organism-taxon-id=4897 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/exports/pombe-japonicus-orthologs-with-systematic-ids.txt.gz

echo starting modifications export at `date`
$POMBASE_CHADO/script/pombase-export.pl ./load-pombase-chado.yaml modifications --organism-taxon-id=4896 "$HOST" $DB $USER $PASSWORD | gzip -9 > $CURRENT_BUILD_DIR/$DB.modifications.gz

echo starting publications with annotations export at `date`
psql $DB -t --no-align -c "
SELECT uniquename FROM pub WHERE uniquename LIKE 'PMID:%'
   AND pub_id IN (SELECT pub_id FROM feature_cvterm UNION SELECT pub_id FROM feature_relationship_pub)
 ORDER BY substring(uniquename FROM 'PMID:(\d+)')::integer;" > $CURRENT_BUILD_DIR/publications_with_annotations.txt
) > $LOG_DIR/$log_file.export_warnings 2>&1

POMBASE_TERMS_OBO=pombase_terms-$DATE_VERSION.obo

$POMBASE_CHADO/script/pombase-export.pl $LOAD_CONFIG ontology \
   --constraint-type=db_name --constraint-value=PBO \
   "$HOST" $DB $USER $PASSWORD > $SOURCES/pombase/$POMBASE_TERMS_OBO


(cd $SOURCES/pombase; ln -sf $POMBASE_TERMS_OBO pombase_terms-latest.obo)

cp $LOG_DIR/$log_file.gaf-load-output $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.legacy_go_from_contigs $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.legacy_phaf_from_contigs $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.biogrid-load-output $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.compara_orths $CURRENT_BUILD_DIR/logs/$log_file.compara-orth-load-output
cp $LOG_DIR/$log_file.manual_multi_orths $CURRENT_BUILD_DIR/logs/$log_file.manual-multi-orths-output
cp $LOG_DIR/$log_file.manual_1-1_orths $CURRENT_BUILD_DIR/logs/$log_file.manual-1-1-orths-output
cp $LOG_DIR/$log_file.malacards_data $CURRENT_BUILD_DIR/logs/$log_file.malacards_data
cp $LOG_DIR/$log_file.disease_associations $CURRENT_BUILD_DIR/logs/$log_file.disease_associations
cp $LOG_DIR/$log_file.curation_tool_data $CURRENT_BUILD_DIR/logs/$log_file.curation-tool-data-load-output
cp $LOG_DIR/$log_file.quantitative $CURRENT_BUILD_DIR/logs/$log_file.quantitative
cp $LOG_DIR/$log_file.qualitative $CURRENT_BUILD_DIR/logs/$log_file.qualitative
cp $LOG_DIR/$log_file.kegg-pathway $CURRENT_BUILD_DIR/logs/$log_file.kegg-pathway
cp $LOG_DIR/$log_file.modification $CURRENT_BUILD_DIR/logs/$log_file.modification
cp $LOG_DIR/$log_file.*phenotypes_from_* $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.export_warnings $CURRENT_BUILD_DIR/logs/$log_file.export_warnings
cp $LOG_DIR/$log_file.excluded_go_terms_softcheck $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.excluded_fypo_terms_softcheck $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.excluded_fypo_terms $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.go-term-mapping $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.add-missing-allele-names $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.fix-allele-names $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.go-filter-*-duplicates $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.chado_checks* $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.qc_queries* $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.allele-synonyms-from-supporting-data $CURRENT_BUILD_DIR/logs/
cp $LOG_DIR/$log_file.allele-comments-from-supporting-data $CURRENT_BUILD_DIR/logs/

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

psql $DB -c "\COPY (select pub.uniquename as pmid, db.name || ':' || x.accession, p.value as comment from feature_cvterm fc join feature_cvtermprop p on fc.feature_cvterm_id = p.feature_cvterm_id join cvterm t on t.cvterm_id = fc.cvterm_id join dbxref x on x.dbxref_id = t.dbxref_id join db on db.db_id = x.db_id join cvterm pt on pt.cvterm_id = p.type_id join pub on fc.pub_id = pub.pub_id where pt.name = 'submitter_comment' order by pub.uniquename) TO STDOUT DELIMITER E'\t' CSV HEADER;" > $CURRENT_BUILD_DIR/logs/$log_file.annotation_comments.tsv

(
echo all protein family term and annotated genes
psql $DB -c "select t.name, db.name || ':' || x.accession as termid, array_to_string(array_agg(f.uniquename), ',') as gene_uniquenames from feature f join feature_cvterm fc on fc.feature_id = f.feature_id join cvterm t on t.cvterm_id = fc.cvterm_id join dbxref x on x.dbxref_id = t.dbxref_id join db on x.db_id = db.db_id join cv on t.cv_id = cv.cv_id where cv.name = 'PomBase family or domain' group by t.name, termid order by t.name, termid;"
) > $CURRENT_BUILD_DIR/logs/$log_file.protein_family_term_annotation

(
echo 'Alleles with type "other"'
psql $DB -F ',' -A -c "select f.name, f.uniquename, (select value from featureprop p where
p.feature_id = f.feature_id and p.type_id in (select cvterm_id from cvterm
where name = 'description')) as description, ARRAY(select value from featureprop p where
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
 parent_cv.cv_id and term_cv.name = 'PomBase annotation extension terms'
 and rel.type_id = rel_type.cvterm_id and rel_type.name =
 'is_a' and fc.feature_cvterm_id in (select feature_cvterm_id from
 feature_cvtermprop where type_id in (select cvterm_id from cvterm
 where name = 'canto_session'))) as sub"
psql $DB -c "select count(distinct fc_id), cv_name from $sub_query group by cv_name order by count;"
psql $DB -c "select count(distinct fc_id) as total from $sub_query;"

 ) > $CURRENT_BUILD_DIR/logs/$log_file.annotation_counts_by_cv

refresh_views


(cd $SOURCES; wget -N http://purl.obolibrary.org/obo/eco/gaf-eco-mapping.txt)

echo creating files for the website:
$POMCUR/bin/pombase-chado-json -c $POMBASE_WEB_CONFIG \
   --doc-config-file ~/git/pombase-website/src/app/config/doc-config.json \
   -p "postgres://kmr44:kmr44@localhost/$DB" \
   -d $CURRENT_BUILD_DIR/ --go-eco-mapping=$SOURCES/gaf-eco-mapping.txt \
   -i /var/pomcur/sources/interpro/pombe_domain_results.json \
   -r /var/pomcur/sources/rnacentral_pombe_rfam.json \
   --gene-history-file $HOME/git/genome_changelog/results/all_previous_coords.tsv \
   --pfam-data-file $SOURCES/pombe-embl/supporting_files/pfam_pombe_protein_data.json \
   --pdb-data-file $SOURCES/pombe-embl/external_data/protein_structure/systematic_id_to_pdbe_mapping.tsv \
   2>&1 | tee $LOG_DIR/$log_file.web-json-write

zstd -9q --rm $CURRENT_BUILD_DIR/api_maps.sqlite3

find $CURRENT_BUILD_DIR/fasta/ -name '*.fa' | xargs gzip -9

cp $LOG_DIR/$log_file.web-json-write $CURRENT_BUILD_DIR/logs/

DB_BASE_NAME=`echo $DB | sed 's/-v[0-9]$//'`

cp -r $SOURCES/current_build_files/$DB_BASE_NAME/* $CURRENT_BUILD_DIR/


cp $LOG_DIR/*.txt $CURRENT_BUILD_DIR/logs/

mkdir $CURRENT_BUILD_DIR/pombe-embl
(
  cd $SOURCES/pombe-embl
  cp -r *.contig external_data mini-ontologies \
    supporting_files orthologs chado_load_mappings \
    $CURRENT_BUILD_DIR/pombe-embl/
)

psql $DB -c 'grant select on all tables in schema public to public;'

DUMP_FILE=$CURRENT_BUILD_DIR/$DB.chado_dump.gz

echo dumping to $DUMP_FILE
pg_dump $DB | gzip -9 > $DUMP_FILE

psql $DB -c 'VACUUM FULL;'

echo
echo building Docker container

(cd ~/git/pombase-chado &&
 nice -10 ./etc/build_container.sh $DATE_VERSION $CURRENT_BUILD_DIR prod /var/pomcur/container_build)

IMAGE_NAME=pombase/web:$DATE_VERSION-prod

echo restarting dev site

docker service update --image=$IMAGE_NAME --replicas 1 pombase-dev

if [ $CHADO_CHECKS_STATUS=passed ]
then
    echo copy JBrowse datasets to the Babraham server
    rsync --delete-during -avHSP /data/pombase/external_datasets/processed/ babraham-pombase:/home/ftp/pombase/external_datasets/

    echo copy  $IMAGE_NAME to server:
    nice -19 docker save $IMAGE_NAME | nice -19 gzip -4v | ssh pombase-admin@149.155.131.177 "gzip -d | sudo docker load" &&
      ssh pombase-admin@149.155.131.177 "sudo docker service update --image $IMAGE_NAME main-1"

    echo copied image to the server

    (cd $SOURCES/pombe-embl/ftp_site/pombe/; svn update)

    gzip -9 < $CURRENT_BUILD_DIR/misc/single_locus_phenotype_annotations_taxon_4896.phaf > $CURRENT_BUILD_DIR/$DB.phaf.gz
    gzip -9 < $CURRENT_BUILD_DIR/misc/single_locus_phenotype_annotations_taxon_4896_eco_evidence.phaf > $CURRENT_BUILD_DIR/$DB.eco.phaf.gz

    cp $CURRENT_BUILD_DIR/misc/gene_IDs_names.tsv          $SOURCES/pombe-embl/ftp_site/pombe/names_and_identifiers/
    cp $CURRENT_BUILD_DIR/misc/gene_IDs_names_products.tsv $SOURCES/pombe-embl/ftp_site/pombe/names_and_identifiers/
    cp $CURRENT_BUILD_DIR/misc/sysID2product.tsv           $SOURCES/pombe-embl/ftp_site/pombe/names_and_identifiers/
    cp $CURRENT_BUILD_DIR/misc/sysID2product.rna.tsv       $SOURCES/pombe-embl/ftp_site/pombe/names_and_identifiers/
    cp $CURRENT_BUILD_DIR/misc/Complex_annotation.tsv      $SOURCES/pombe-embl/ftp_site/pombe/annotations/Gene_ontology/GO_complexes/Complex_annotation.tsv

    cp $CURRENT_BUILD_DIR/misc/*.exon.coords.tsv      $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/Exon_Coordinates/
    cp $CURRENT_BUILD_DIR/misc/*.cds.coords.tsv      $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/CDS_Coordinates/

    gzip -9 < $CURRENT_BUILD_DIR/misc/gene_product_annotation_data_taxonid_4896.tsv > $SOURCES/pombe-embl/ftp_site/pombe/annotations/Gene_ontology/pombase.gpad.gz
    gzip -9 < $CURRENT_BUILD_DIR/misc/gene_product_information_taxonid_4896.tsv     > $SOURCES/pombe-embl/ftp_site/pombe/annotations/Gene_ontology/pombase.gpi.gz
    gzip -9 < $CURRENT_BUILD_DIR/misc/go_style_gaf.tsv                              > $SOURCES/pombe-embl/ftp_site/pombe/annotations/Gene_ontology/gene_association_2-2.pombase.gz
    gzip -9 < $CURRENT_BUILD_DIR/misc/pombase_style_gaf.tsv                         > $SOURCES/pombe-embl/ftp_site/pombe/annotations/Gene_ontology/gene_association_2-1.pombase.gz

    cp $SOURCES/pombe-embl/ftp_site/pombe/annotations/Gene_ontology/gene_association_2-1.pombase.gz $CURRENT_BUILD_DIR/$DB.gaf.gz

    cp $CURRENT_BUILD_DIR/misc/FYPOviability.tsv           $SOURCES/pombe-embl/ftp_site/pombe/annotations/Phenotype_annotations/FYPOviability.tsv
    cp $CURRENT_BUILD_DIR/misc/transmembrane_domain_coords_and_seqs.tsv    $SOURCES/pombe-embl/ftp_site/pombe/Protein_data/transmembrane_domain_coords_and_seqs.tsv
    cp $CURRENT_BUILD_DIR/misc/pombe_mondo_slim_ids_and_names.tsv          $SOURCES/pombe-embl/ftp_site/pombe/documents/pombe_mondo_slim_ids_and_names.tsv

    cp $CURRENT_BUILD_DIR/exports/pombase-go-physical-interactions.tsv.gz  $SOURCES/pombe-embl/ftp_site/pombe/high_confidence_physical_interactions/
    cp $CURRENT_BUILD_DIR/exports/pombase-go-substrates.tsv.gz             $SOURCES/pombe-embl/ftp_site/pombe/high_confidence_physical_interactions/

    gzip -d < $CURRENT_BUILD_DIR/exports/pombe-human-orthologs-with-systematic-ids.txt.gz      > $SOURCES/pombe-embl/ftp_site/pombe/orthologs/pombe-human-orthologs.tsv
    gzip -d < $CURRENT_BUILD_DIR/exports/pombe-cerevisiae-orthologs-with-systematic-ids.txt.gz > $SOURCES/pombe-embl/ftp_site/pombe/orthologs/pombe-cerevisiae-orthologs.tsv
    gzip -d < $CURRENT_BUILD_DIR/exports/pombe-japonicus-orthologs-with-systematic-ids.txt.gz > $SOURCES/pombe-embl/ftp_site/pombe/orthologs/pombe-japonicus-orthologs.tsv

    gzip -d < $CURRENT_BUILD_DIR/pombase-latest.cerevisiae-orthologs.txt.gz      > $SOURCES/pombe-embl/ftp_site/pombe/orthologs/pombe-cerevisiae-orthologs-one-line-per-gene.tsv
    gzip -d < $CURRENT_BUILD_DIR/pombase-latest.human-orthologs.txt.gz           > $SOURCES/pombe-embl/ftp_site/pombe/orthologs/pombe-human-orthologs-one-line-per-gene.tsv
    gzip -d < $CURRENT_BUILD_DIR/pombase-latest.japonicus-orthologs.txt.gz       > $SOURCES/pombe-embl/ftp_site/pombe/orthologs/pombe-japonicus-orthologs-one-line-per-gene.tsv

    cp $CURRENT_BUILD_DIR/$DB.human-orthologs.txt.gz       $SOURCES/pombe-embl/ftp_site/pombe/orthologs/human-orthologs.txt.gz

    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/cds+introns+utrs.fa.gz   $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/feature_sequences/cds+introns+utrs.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/cds+introns.fa.gz        $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/feature_sequences/cds+introns.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/cds.fa.gz                $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/feature_sequences/cds.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/introns_within_cds.fa.gz $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/feature_sequences/introns_within_cds.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/five_prime_utrs.fa.gz    $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/feature_sequences/UTR/5UTR.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/three_prime_utrs.fa.gz   $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/feature_sequences/UTR/3UTR.fa.gz
    cp $CURRENT_BUILD_DIR/fasta/feature_sequences/peptide.fa.gz            $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/feature_sequences/peptide.fa.gz

    cp $CURRENT_BUILD_DIR/fasta/chromosomes/*.gz  $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/genome_sequence/

    for f in all_chromosomes chr_II_telomeric_gap chromosome_I chromosome_II \
             chromosome_III mating_type_region mitochondrial_chromosome
    do
        file_name=Schizosaccharomyces_pombe_$f.gff3
        gzip -9 < $CURRENT_BUILD_DIR/gff/$file_name > $SOURCES/pombe-embl/ftp_site/pombe/genome_sequence_and_features/gff3/$file_name.gz
    done

    cp $CURRENT_BUILD_DIR/$DB.modifications.gz             $SOURCES/pombe-embl/ftp_site/pombe/annotations/modifications/pombase-chado.modifications.gz
    cp $CURRENT_BUILD_DIR/$DB.phaf.gz                      $SOURCES/pombe-embl/ftp_site/pombe/annotations/Phenotype_annotations/phenotype_annotations.pombase.phaf.gz

    (cd $SOURCES/pombe-embl/ftp_site/pombe/; svn commit -m "Automatic file update for $DB")

    rm -f $DUMPS_DIR/nightly_update
    rm -f $DUMPS_DIR/latest_build

    ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/nightly_update
    ln -s $CURRENT_BUILD_DIR $DUMPS_DIR/latest_build

    rsync -aH --delete-after $CURRENT_BUILD_DIR/ pombase-admin@149.155.131.177:/home/ftp/pombase/nightly_update/

    #  --delete-after
    rsync -aHS $SOURCES/pombe-embl/ftp_site/pombe/ pombase-admin@149.155.131.177:/home/ftp/pombase/pombe/
fi

if [ `date '+%A'` = 'Sunday' ]
then
  perl -pne 's/^PMID://' < $CURRENT_BUILD_DIR/publications_with_annotations.txt > /tmp/holdings.uid
  gzip -9 < /tmp/holdings.uid > /tmp/holdings.uid.gz

  curl -T /tmp/holdings.uid ftp://pombase:$PUBMED_PASSWORD@ftp-private.ncbi.nlm.nih.gov/holdings/holdings.uid
  curl -T /tmp/holdings.uid.gz ftp://elinks:$EPMC_PASSWORD@labslink.ebi.ac.uk/$EPMC_DIRECTORY/holdings.uid.gz
fi

echo "$DB" > $SOURCES/current_pombase_database.txt
echo "$DATE_VERSION" > $SOURCES/current_pombase_database_date.txt

cat > $POMCUR/apps/pombe/canto_chado.yaml <<EOF

Model::ChadoModel:
  connect_info:
    - dbi:Pg:dbname=$DB;host=localhost
    - pbuild
    - pbuild
  schema_class: Canto::ChadoDB

EOF

echo build and deploy allele_qc container

(cd $HOME/git/allele_qc
 git pull
 docker build -f Dockerfile -t pombase/allele_qc:$DATE_VERSION .
 docker service update --replicas 2 allele_qc
 docker service update --image pombase/allele_qc:$DATE_VERSION allele_qc
 docker service update --replicas 1 allele_qc)

curl -X 'POST' \
  'https://dev.apicuron.org/api/reports/bulk' \
  -H 'accept: */*' \
  -H 'version: 2' \
  -H 'authorization: bearer '$APICURON_API_KEY \
  -H 'Content-Type: multipart/form-data' \
  -F 'delete_all=pombase' \
  -F 'reports=@'$CURRENT_BUILD_DIR'/misc/apicuron_data.json;type=application/json'

echo
date
echo sucessfully finished building: $DB
