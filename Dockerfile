FROM trinodb/trino:440

COPY ./conf/catalog.properties /etc/trino/catalog.properties
COPY ./conf/catalog/ /etc/trino/catalog/
