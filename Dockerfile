FROM trinodb/trino:438

COPY ./conf/catalog.properties /etc/trino/catalog.properties
COPY ./conf/catalog/delta_lake.properties /etc/trino/catalog/delta_lake.properties
