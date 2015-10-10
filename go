gradle clean oneJar
java -jar -Done-jar.silent=true build/libs/docker-dropwizard-example-standalone.jar server config.yml
