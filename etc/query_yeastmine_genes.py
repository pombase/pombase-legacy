#!/usr/bin/env python3

# retreive basic cerevisiae gene information from the Alliance as a
# tab-delimited file

# needs InterMine Python module: pip3 install intermine

from intermine.webservice import Service
service = Service("https://www.alliancegenome.org/alliancemine/service")

import re

# InterMine XML for query:
'''
<query model="genomic" view="Gene.primaryIdentifier Gene.symbol Gene.featureType Gene.name Gene.secondaryIdentifier Gene.modDescription" sortOrder="Gene.primaryIdentifier ASC" >
  <constraint path="Gene.organism.name" op="=" value="Saccharomyces cerevisiae" code="A" />
</query>
'''

# Get a new query on the class (table) you will be querying:
query = service.new_query("Gene")

# The view specifies the output columns
query.add_view(
    "primaryIdentifier", "symbol", "featureType", "name", "secondaryIdentifier",
    "modDescription"
)

#query.add_constraint("organism.taxonId", "=", "4932", code="A")
query.add_constraint("organism.name", "=", "Saccharomyces cerevisiae", code="A")

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
                row["modDescription"],
                row["secondaryIdentifier"],
                row["symbol"]]
    print("\t".join(map(fix_field, row_list)))
