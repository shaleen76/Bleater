Bleater (CSCI 621 NoSQL Project)
===========
Authors: Shaleen Agarwal, Svyatoslav Sivov, Evan Wheeler

Bleater is a social network designed for ungulates, although we hope to expand our userbase to humans. Bleater is an improvement over twitter, in that bleats can be up to *216 characters*, while tweets are capped at a measly 140.

This project was done to show off the capabilities of the Riak database. The front-end (app.rb) is built on Sinatra, serving web pages constructed using haml; the back-end that interacts with the database makes use of the Riak client library for Ruby. Of interest to you may be the Javascript code for the map-reduce phases that we use to fetch a user's timeline under src/js/mr.js. Not on this repository (but in our submission to the professor) should be scripts to reset the database, populate it with test users, set users to follow each other and post random tweets.

You should be able to build this yourself (assuming you've installed ruby and rubygems) by first navigating to the root directory and pulling in the dependencies with
```
gem install bundler
```
and then installing them:
```
bundle install
```
and then starting Rack and running the application:
```
rackup config.ru -p 8080
```

However, you can simply access the site at http://104.236.35.18 (provided Evan hasn't shut down the VPS) and we recommend you do this instead.

P.S. We are aware that the database is not structured in the most efficient way. Chiefly, the buckets are structured to facilitate using M/R for fetching timelines, despite Riak M/R being 1) computationally expensive, 2) having unpredictable latency, and 3) being contrary to the principle that (when using Riak) business logic should reside in the application layer, not the database layer. However, this was a conscious decision made for the sake of showing off the M/R capabilites of Riak.
