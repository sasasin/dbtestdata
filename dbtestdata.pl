#! perl --
{
  package dbtestdata;
  
  use strict;
  use warnings;
  use data::VariableDataGenerator;
  use sql::VariableSQLGenerator;
  use utf8;
  use DBI;
  use Getopt::Long;
  use IO::Handle;
  STDOUT->autoflush(1);

  ##
  # DBテストデータ作成ツール。
  # 
  # usage:
  #   perl dbtestdata.pl insert|update|delete OPTIONS
  ##
  
  my $PULSE_COMMIT = 10000;
  our %options = (
    'conf' => []
  );

  exit main();

  ##
  # エントリポイント
  ##
  sub main {
    GetOptions(
        \%options,
        "username:s",
        "password",
        "database:s",
        "hostname:s",
        "conf:s@"
    );

    my $mode = $ARGV[0];
    my @confs = @{ $options{'conf'} || [] };
    
    if ($mode !~ m/^(insert|update|delete)$/) {
      die "unknown mode";
    }
    map{ -f($_) || die "conf not found: $_"; }@confs;
    
    my $db = getConnection();
    foreach my $conffile (@confs) {
      my $config = require($conffile);
      my $proc = "main_${mode}";
      
      STDOUT->print("<", $config->{'name'}, ">\n");
      no strict 'refs';
      $proc->($db, $config);
    }
    
    STDOUT->print("\n");
    STDOUT->print("ended.\n");
    
    return 0;
  }

  ##
  # DBIを返す
  ##
  sub getConnection() {
    my $password = undef;
    if ($options{'password'}) {
      while (1) {
        STDERR->print("password: ");
        STDERR->flush();
        $password = STDIN->getline();
        chomp($password);
        $password && last;
      }
    }
    
    my $db = DBI->connect(
      sprintf("dbi:mysql:%s:%s", $options{'database'} || '', $options{'hostname'} || ''),
      $options{'username'},
      $password
    ) || die $DBI::error;
    
    # ここがMySQL5依存(^^;
    $db->do("SET NAMES utf8");
    $db->do("SET SESSION wait_timeout = 1000000");
    
    return $db;
  }

  ##
  # テストデータのINSERTをします
  ##
  sub main_insert {
    my($db, $config) = @_;
    
    local $| = 1;
    $db->{AutoCommit} = 0;
    my $confInsert = $config->{'insert'};
    
    while (my($table, $conf) = each(%$confInsert)) {
      $table = "`$table`";
      STDOUT->print("INSERT $table\n");
      
      my $count = 0;
      while ($count < $conf->{'count'}) {
        $count++;
        
        $db->do(
          INSERT_SQL(
            $table,
            (ref($conf->{'clazz'}) eq 'CODE') ? $conf->{'clazz'}->($count) : $conf->{'clazz'}
          )
        ) || die $DBI::error;
        
        if (! ($count % $PULSE_COMMIT)) {
          my $bar = $count % ($PULSE_COMMIT*2) ? '|' : '-';
          $db->commit() || die $DBI::error;
          STDOUT->print("\r$bar $count commited.");
        }
      }
      
      $db->commit() || die $DBI::error;
      STDOUT->print("\r+ $count commited.\n");
      
      STDOUT->print("finished.\n");
    }
  }

  ##
  # テストデータのUPDATEをします
  ##
  sub main_update {
    my($db, $config) = @_;
    
    local $| = 1;
    $db->{AutoCommit} = 0;
    my $confUpdate = $config->{'update'};
    
    while (my($table, $conf) = each(%$confUpdate)) {
      $table = "`$table`";
      STDOUT->print("UPDATE $table\n");
      
      my $sql_count = sprintf("SELECT ifnull(max(%s), 0) FROM %s", $conf->{'primary'}, $table);
      my $sth = $db->prepare($sql_count) || die $DBI::error;
      $sth->execute() || die $DBI::error;
      my @primaryKeysCount;
      while (my $row = $sth->fetchrow_arrayref()) {
        push(@primaryKeysCount, $row->[0]);
      }
      STDOUT->print("$primaryKeysCount[0] records will update.\n");

      my $cursor = 0;
      my $count = 0;
      while ($cursor <= $primaryKeysCount[0]) {
        my $sql = sprintf("SELECT %s FROM %s WHERE %s BETWEEN %s AND (%s + %s)", $conf->{'primary'}, $table, $conf->{'primary'}, $cursor, $cursor, $PULSE_COMMIT);
        $sth = $db->prepare($sql) || die $DBI::error;
        $sth->execute() || die $DBI::error;
        
        my @primaryKeys;
        while (my $row = $sth->fetchrow_arrayref()) {
          push(@primaryKeys, $row->[0]);
        }
        
        foreach my $pk (@primaryKeys) {
          $count++;
          
          $db->do(
            UPDATE_SQL(
              $table,
              (ref($conf->{'clazz'}) eq 'CODE') ? $conf->{'clazz'}->($pk) : $conf->{'clazz'},
              [ WHERE($conf->{'primary'}, $pk) ]
            )
          ) || die $DBI::error;
          
          if (! ($count % $PULSE_COMMIT)) {
            my $bar = $count % ($PULSE_COMMIT*2) ? '|' : '-';
            $db->commit() || die $DBI::error;
            STDOUT->print("$bar $count commited.\n");
          }
        }

        $cursor += $PULSE_COMMIT;
      }
      
      $db->commit() || die $DBI::error;
      STDOUT->print("+ $count commited.\n");
      
      STDOUT->print("finished.\n");
    }
  }

  ##
  # レコードを全DELETEします
  ##
  sub main_delete {
    my($db, $config) = @_;
    
    $db->{AutoCommit} = 1;
    my $confDelete = $config->{'delete'};
    
    foreach my $t (@$confDelete) {
      $t = "`$t`";
      STDOUT->print("DELETE $t\n");
      $db->do("DELETE FROM $t") || die $DBI::error;
      STDOUT->print("finished.\n");
    }
  }
  
  1;
}

__END__
