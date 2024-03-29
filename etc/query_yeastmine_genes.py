#!/usr/bin/env python3

# retreive basic gene information from SGD as a tab-delimited file

# needs InterMine Python module: pip3 install intermine

from intermine.webservice import Service
service = Service("https://yeastmine.yeastgenome.org/yeastmine/service")

import re

# InterMine XML for query:
'''
<query name="" model="genomic" view="Gene.primaryIdentifier Gene.symbol Gene.featureType Gene.name Gene.secondaryIdentifier Gene.description" longDescription="" sortOrder="Gene.secondaryIdentifier asc">
  <constraint path="Gene.organism.taxonId" op="=" value="4932"/>
</query>
'''

# Get a new query on the class (table) you will be querying:
query = service.new_query("Gene")

# The view specifies the output columns
query.add_view(
    "primaryIdentifier", "symbol", "featureType", "name", "secondaryIdentifier",
    "description"
)

query.add_constraint("organism.taxonId", "=", "4932", code="A")

def fix_field(el):
    if el is None:
        return ''
    else:
        return el.replace('\n', ' ')

for row in query.rows():
    primary_identifier = row["primaryIdentifier"]
    if primary_identifier is None:
        continue  # probably a human gene

    primary_identifier = re.sub(r"^(S[0-9]{9})$", r"SGD:\1", row["primaryIdentifier"])

    row_list = [row["featureType"],
                row["name"],
                primary_identifier,
                row["description"],
                row["secondaryIdentifier"],
                row["symbol"]]
    print("\t".join(map(fix_field, row_list)))
