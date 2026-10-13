FROM placeos/crystal:latest

WORKDIR /app

COPY . /app

# NOTE:: add `--branch my-new-model-branch` if you want to test a particular branch
RUN git clone --branch PPT-2832-ai-map-review https://github.com/PlaceOS/models
RUN mv ./models/migration/db ./db

ENV PATH /app/bin:$PATH

RUN shards build

ENTRYPOINT [ "/app/run.sh" ]
