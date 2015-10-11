FROM java:8-jre
COPY config.yml /opt/dropwizard/
COPY build/libs/docker-dropwizard-example-standalone.jar /opt/dropwizard/
#EXPOSE 8080
WORKDIR /opt/dropwizard
RUN wget -q https://storage.googleapis.com/cloud-debugger/compute-java/format_env_gce.sh \
    && chmod +x format_env_gce.sh
ENV CDBG_ARGS "$( sudo ./format_env_gce.sh --app_class_path=/opt/dropwizard/docker-dropwizard-example-standalone.jar --version=1.0.0 )"

CMD ["java", "-jar", "${CDBG_ARGS}", "-Done-jar.silent=true", "docker-dropwizard-example-standalone.jar", "server", "config.yml"]
