# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
FROM ruby:4.0.7-slim-bookworm@sha256:b21bc6c2360f7b7b615ff8860f239b12b2c6634ec026712745743b0661ac14b9 AS runtime-base
RUN apt-get update && apt-get install -y --no-install-recommends util-linux ca-certificates iproute2 nftables \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 skvoz && useradd --uid 10001 --gid 10001 --no-create-home skvoz \
    && install -d -m 0755 /var/lib/skvoz-client \
    && install -d -o 10001 -g 10001 -m 0700 /var/lib/skvoz-client/app /run/skvoz-client \
    && install -d -m 0700 /var/lib/skvoz-client/boot
WORKDIR /opt/skvoz/client
COPY Gemfile Gemfile.lock ./
COPY lib lib
COPY bin/skvoz-client bin/skvoz-client
RUN ln -s /opt/skvoz/client/bin/skvoz-client /usr/local/bin/skvoz-client
ENV BUNDLE_GEMFILE=/opt/skvoz/client/Gemfile BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=test BUNDLE_FROZEN=true
HEALTHCHECK --interval=5s --timeout=3s --start-period=60s --retries=2 CMD ["skvoz-client", "health"]
ENTRYPOINT ["skvoz-client"]
CMD ["serve"]

FROM ruby:4.0.7-bookworm@sha256:119a36c51c7893215202220eabfdcb561638735de4d45bacf2e8619be3de47f2 AS gems
WORKDIR /opt/skvoz/client
ENV BUNDLE_PATH=/usr/local/bundle
COPY Gemfile Gemfile.lock ./
RUN gem install bundler --version 4.0.22 --no-document \
    && bundle config set deployment true && bundle config set without test \
    && bundle install && bundle clean --force

FROM gems AS tests
COPY lib lib
COPY spec spec
COPY bin bin
RUN bundle config unset without && bundle install
CMD ["bundle", "exec", "rspec", "spec"]

FROM gems AS native
ARG NETWORK_LOCK=artifacts/network.lock.json
ARG NETWORK_ARCHIVE=artifacts/native/network-current-identity.tar.gz
COPY bin/install-native bin/install-native
COPY lib/skvoz/client/native_artifact.rb lib/skvoz/client/native_artifact.rb
COPY ${NETWORK_LOCK} /native/lock.json
COPY ${NETWORK_ARCHIVE} /native/bundle.tar.gz
RUN bundle exec ruby bin/install-native /native/lock.json /opt/skvoz-native /native/bundle.tar.gz

FROM runtime-base AS deploy
LABEL org.opencontainers.image.source="https://github.com/skvoz-project/skvoz-client-service"
COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY --from=native /opt/skvoz-native/bin/skvoz-network-runtime /opt/skvoz-native/bin/skvoz-network-helper /opt/skvoz-native/bin/
COPY --from=native /opt/skvoz-native/lib /opt/skvoz-native/lib
COPY --from=native /opt/skvoz-native/resources /opt/skvoz-native/resources
COPY --from=native /opt/skvoz-native/licenses /opt/skvoz-native/licenses
COPY --from=native /opt/skvoz-native/manifest.json /opt/skvoz-native/supplier-manifest.json
COPY --from=native /opt/skvoz-native/source-inputs.sha256 /opt/skvoz-native/source-inputs.sha256
RUN ln -s /opt/skvoz-native/bin/skvoz-network-runtime /usr/local/bin/skvoz-network-runtime \
    && bundle check && skvoz-client --version
