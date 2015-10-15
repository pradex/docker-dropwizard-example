FROM gcr.io/oauth-1710/oracle8u60
COPY config.yml /opt/dropwizard/
COPY build/libs/docker-dropwizard-example-standalone.jar /opt/dropwizard/
COPY oauth-project-e9b592592ac8.p12 /opt/dropwizard/
RUN sudo apt-get update && sudo apt-get install -y ca-certificates
EXPOSE 8080
WORKDIR /opt/dropwizard

CMD java $( wget --no-check-certificate -q -O - https://storage.googleapis.com/cloud-debugger/compute-java/format_env_gce.sh | \
  sudo bash -- /dev/stdin --app_class_path=docker-dropwizard-example-standalone.jar --version=1.0.0 \
  --enable_service_account_auth --project_id=oauth-1710 --verbose \
--project_number=364426739259 --service_account_email=364426739259-opjf8ghcov7iutcr3dvmhmrgrufpqc0g@developer.gserviceaccount.com \
--service_account_p12_file=oauth-project-e9b592592ac8.p12 ) -jar -Done-jar.silent=true docker-dropwizard-example-standalone.jar server config.yml
