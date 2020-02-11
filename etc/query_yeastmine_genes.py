#!/usr/bin/env python3

# retreive basic gene information from SGD as a tab-delimited file

# The following two lines will be needed in every python script:
from intermine.webservice import Service
service = Service("https://yeastmine.yeastgenome.org/yeastmine/service")

# Get a new query on the class (table) you will be querying:
query = service.new_query("Gene")

# The view specifies the output columns
query.add_view(
    "featureType", "name", "primaryIdentifier", "sgdAlias", "description",
    "transcripts.primaryIdentifier", "secondaryIdentifier", "symbol"
)

# Uncomment and edit the line below (the default) to select a custom sort order:
# query.add_sort_order("Gene.featureType", "ASC")

# Outer Joins
# (display properties of these relations if they exist,
# but also show objects without these relationships)
query.outerjoin("transcripts")

def null_to_empty(el):
    if el is None:
        return ''
    else:
        return el


for row in query.rows():
    row_list = [row["featureType"], row["name"], row["primaryIdentifier"],
                row["sgdAlias"], row["description"],
                row["transcripts.primaryIdentifier"],
                row["secondaryIdentifier"], row["symbol"]]
    print("\t".join(map(null_to_empty, row_list)))
