# Celluloid::Eventsource

To release:
1. Bump version in version.rb
1. Commit changes and tag with version: ie 0.8.4
1. `VERSION=0.8.4 && git tag $VERSION && git push origin $VERSION && gem build ld-celluloid-eventsource.gemspec && gem push ld-celluloid-eventsource-$VERSION.gem`
1. Release on Github