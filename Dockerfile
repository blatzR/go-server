FROM ubunutu:22.04

WORKDIR /app

COPY . .

RUN sudo apt update
RUN sudo apt install golang-go

RUN go -version

RUN go build -o myapp

EXPOSE 8080

CMD ["./myapp"]

