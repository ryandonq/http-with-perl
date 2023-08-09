use strict;
use warnings;
use Cwd;
use File::Basename;
use Parallel::ForkManager;
use IPC::System::Simple qw(system);
use HTTP::Tiny;
use Getopt::Long;
use Term::ANSIColor qw(colored);
use Time::HiRes qw(time);
use Sort::Key::Top qw(rnkeytop);

my $compare_dir = dirname(__FILE__) . '/comp';
my @files = sort grep { /\.js$/ } readdir($compare_dir);

my %opts;
GetOptions(
    'u=s' => \$opts{url},
    'c=i' => \$opts{connections},
    'p=i' => \$opts{pipelining},
    'd=i' => \$opts{duration}
);

$opts{url} //= 'http://localhost:88';
$opts{connections} //= 100;
$opts{pipelining} //= 10;
$opts{duration} //= 5;

sub autocannon {
    my $title = shift;
    my $result;
    
    my $cmd = "autocannon -c $opts{connections} -p $opts{pipelining} -d $opts{duration} $opts{url}";
    my $output = `$cmd 2>&1`;
    
    if ($output =~ /Requests\/s:\s+(\d+\.\d+)/ && $output =~ /Latency:\s+(\d+\.\d+)/ && $output =~ /Throughput:\s+(\d+\.\d+)/) {
        $result = {
            title => $title,
            requests => $1,
            latency => $2,
            throughput => $3
        };
    }
    
    return $result;
}

my @results;
my $pm = Parallel::ForkManager->new(scalar @files);

for my $file (@files) {
    $pm->start and next;

    my $title = colored("Warming up $file", 'yellow');
    my $start = time();
    my $response = HTTP::Tiny->new->get($opts{url});
    my $end = time();
    my $elapsed = $end - $start;

    print "$title\n";
    sleep(1);

    my $spin = colored("Running $file", 'green');
    print "$spin\n";

    my $result = autocannon($file);

    print colored("$file\n", 'blue');
    push @results, $result;

    $pm->finish;
}

$pm->wait_all_children;

@results = rnkeytop { $_->{requests} } @results;

print colored("Benchmark Results:\n", 'blue');
print sprintf("%-50s %-15s %-15s %-15s\n", "Title", "Requests/s", "Latency", "Throughput/Mb");

for my $result (@results) {
    printf "%-50s %-15s %-15s %-15s\n", $result->{title}, $result->{requests}, $result->{latency}, ($result->{throughput} / 1024 / 1024);
}
