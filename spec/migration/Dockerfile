FROM placeos/crystal:latest

WORKDIR /app

COPY . /app

# NOTE:: add `--branch my-new-model-branch` if you want to test a particular branch
RUN git clone https://github.com/PlaceOS/models
RUN mv ./models/migration/db ./db

ENV PATH /app/bin:$PATH

RUN shards build

ENTRYPOINT [ "/app/run.sh" ]
