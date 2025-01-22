FROM trinodb/trino:445

COPY ./conf/catalog.properties /etc/trino/catalog.properties
COPY ./conf/catalog/ /etc/trino/catalog/
