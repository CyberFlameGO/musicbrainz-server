package t::MusicBrainz::Server::Controller::Artist::Relationships;
use Test::Routine;
use Test::More;
use MusicBrainz::Server::Test qw( html_ok page_test_jsonld );

with 't::Mechanize', 't::Context';

use aliased 'MusicBrainz::Server::Entity::PartialDate';

test all => sub {

my $test = shift;
my $mech = $test->mech;
my $c    = $test->c;

MusicBrainz::Server::Test->prepare_test_database($c, '+controller_artist');

# Test relationships
$mech->get_ok('/artist/745c079d-374e-4436-9448-da92dedef3ce/relationships', 'get artist relationships');
html_ok($mech->content);
$mech->content_contains('guitar');
$mech->content_contains('/recording/123c079d-374e-4436-9448-da92dedef3ce');

page_test_jsonld $mech => {
    'location' => {
        'name' => 'United Kingdom',
        '@id' => 'http://musicbrainz.org/area/8a754a16-0027-3a29-b6d7-2b40ea0481ed',
        '@type' => 'Country'
    },
    '@context' => 'http://schema.org',
    '@type' => ['Person', 'MusicGroup'],
    'birthDate' => '2008-01-02',
    'birthPlace' => {
        '@type' => 'Country',
        '@id' => 'http://musicbrainz.org/area/8a754a16-0027-3a29-b6d7-2b40ea0481ed',
        'name' => 'United Kingdom'
    },
    'name' => 'Test Artist',
    'deathDate' => '2009-03-04',
    'deathPlace' => {
        'name' => 'United Kingdom',
        '@id' => 'http://musicbrainz.org/area/8a754a16-0027-3a29-b6d7-2b40ea0481ed',
        '@type' => 'Country'
    },
    '@id' => 'http://musicbrainz.org/artist/745c079d-374e-4436-9448-da92dedef3ce'
};

};

1;
