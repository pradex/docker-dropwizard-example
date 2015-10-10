FROM java:8-jre
COPY config.yml /opt/dropwizard/
COPY build/libs/docker-dropwizard-example-standalone.jar /opt/dropwizard/
#EXPOSE 8080
WORKDIR /opt/dropwizard
CMD ["java", "-jar", "-Done-jar.silent=true", "docker-dropwizard-example-standalone.jar", "server", "config.yml"]
