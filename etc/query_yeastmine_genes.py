#!/usr/bin/env python3

# retreive basic gene information from SGD as a tab-delimited file

# The following two lines will be needed in every python script:
from intermine.webservice import Service
service = Service("https://yeastmine.yeastgenome.org/yeastmine/service")

# Get a new query on the class (table) you will be querying:
query = service.new_query("Gene")

# The view specifies the output columns
query.add_view(
    "primaryIdentifier", "symbol", "featureType", "name", "secondaryIdentifier",
    "description"
)

def fix_field(el):
    if el is None:
        return ''
    else:
        return el.replace('\n', ' ')

for row in query.rows():
    row_list = [row["featureType"],
                row["name"],
                row["primaryIdentifier"],
                row["description"],
                row["secondaryIdentifier"],
                row["symbol"]]
    print("\t".join(map(fix_field, row_list)))
