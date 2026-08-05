FROM placeos/crystal:latest

WORKDIR /app

COPY . /app

# NOTE:: add `--branch my-new-model-branch` if you want to test a particular branch
# TODO(PPT-2644): drop the --branch pin once the search_vector migration merges to models master
RUN git clone --branch PPT-2644-pg-full-text-search https://github.com/PlaceOS/models
RUN mv ./models/migration/db ./db

ENV PATH /app/bin:$PATH

RUN shards build

ENTRYPOINT [ "/app/run.sh" ]
