# Use the official Erlang image as the base
FROM erlang:29-slim

# Set the working directory
WORKDIR /app

# Copy the current directory contents into the container at /app
COPY . /app

# Install any needed packages specified in rebar.config
RUN rebar3 compile

# Make port 8080 available to the world outside this container
EXPOSE 8080

# Run the application
CMD erl -pa _build/default/lib/*/ebin \
    -eval "application:ensure_all_started(web)" \
    -noshell \
    +Bd
