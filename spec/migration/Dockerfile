FROM placeos/crystal:latest

WORKDIR /app

COPY . /app

# NOTE:: add `--branch my-new-model-branch` if you want to test a particular branch
# PPT-526: the tenancy migrations live on this branch until models #332 merges
RUN git clone --branch PPT-526-partner-client https://github.com/PlaceOS/models
RUN mv ./models/migration/db ./db

ENV PATH /app/bin:$PATH

RUN shards build

ENTRYPOINT [ "/app/run.sh" ]
