package conf

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	puresqlite "github.com/glebarez/sqlite"
	"github.com/spf13/viper"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"gorm.io/gorm/schema"
)

func InitDB() (*gorm.DB, error) {
	level := logger.Info
	if !viper.GetBool("mode.develop") {
		level = logger.Error
	}

	driver := detectDBDriver()
	dsn := strings.TrimSpace(viper.GetString("DB.dsn"))
	if err := ensureSQLiteDir(driver, dsn); err != nil {
		return nil, err
	}

	dialector, err := buildDialector(driver, dsn)
	if err != nil {
		return nil, err
	}

	db, err := gorm.Open(dialector, &gorm.Config{
		NamingStrategy: schema.NamingStrategy{
			TablePrefix:   "sys_",
			SingularTable: true,
		},
		Logger: logger.Default.LogMode(level),
	})
	if err != nil {
		return nil, err
	}
	sqlDB, _ := db.DB()
	if driver == "sqlite" {
		// SQLite 单写锁：连接池必须串行，否则多连接并发写直接 "database is locked"，
		// 慢事务（旧删除用户把夸克网络请求塞事务内）一拖就把整库锁死，
		// 鉴权中间件读不到用户直接 401 踢登录。
		sqlDB.SetMaxOpenConns(1)
		sqlDB.SetMaxIdleConns(1)
	} else {
		sqlDB.SetMaxOpenConns(viper.GetInt("DB.MaxOpenConns"))
		sqlDB.SetMaxIdleConns(viper.GetInt("DB.MaxIdleConns"))
	}
	sqlDB.SetConnMaxLifetime(time.Hour)

	if driver == "sqlite" {
		if err := applySQLitePragmas(db); err != nil {
			return nil, err
		}
	}

	if viper.GetBool("DB.AutoMigrate") {
		if err := InitSchema(db); err != nil {
			return nil, err
		}
	}

	if viper.GetBool("DB.InitData") {
		if err := importInitSQLIfNeeded(db); err != nil {
			return nil, err
		}
	}

	if err := migrateQuarkApplications(db); err != nil {
		return nil, err
	}

	if err := ensureQuarkAccountShareModeSeed(db); err != nil {
		return nil, err
	}

	return db, nil
}

func detectDBDriver() string {
	driver := strings.ToLower(strings.TrimSpace(viper.GetString("DB.driver")))
	if driver != "" {
		return driver
	}

	dsn := strings.ToLower(strings.TrimSpace(viper.GetString("DB.dsn")))
	if strings.Contains(dsn, "@tcp(") || strings.Contains(dsn, "charset=") {
		return "mysql"
	}
	return "sqlite"
}

func buildDialector(driver string, dsn string) (gorm.Dialector, error) {
	switch driver {
	case "mysql":
		if strings.TrimSpace(dsn) == "" {
			return nil, fmt.Errorf("mysql dsn 不能为空")
		}
		return mysql.Open(dsn), nil
	case "sqlite":
		if strings.TrimSpace(dsn) == "" {
			dsn = "./data/ohome.db"
		}
		return puresqlite.Open(dsn), nil
	default:
		return nil, fmt.Errorf("不支持的数据库驱动: %s", driver)
	}
}

func ensureSQLiteDir(driver string, dsn string) error {
	if driver != "sqlite" {
		return nil
	}

	path, ok := resolveSQLiteFilePath(dsn)
	if !ok {
		return nil
	}

	return os.MkdirAll(filepath.Dir(path), 0o755)
}

func resolveSQLiteFilePath(dsn string) (string, bool) {
	dsn = strings.TrimSpace(dsn)
	if dsn == "" {
		return "./data/ohome.db", true
	}

	lowerDSN := strings.ToLower(dsn)
	if dsn == ":memory:" || strings.Contains(lowerDSN, "mode=memory") {
		return "", false
	}

	if strings.HasPrefix(lowerDSN, "file:") {
		trimmed := strings.TrimPrefix(dsn, "file:")
		trimmed = strings.SplitN(trimmed, "?", 2)[0]
		if strings.TrimSpace(trimmed) == "" {
			return "", false
		}
		return trimmed, true
	}

	return strings.SplitN(dsn, "?", 2)[0], true
}

func applySQLitePragmas(db *gorm.DB) error {
	pragmas := []string{
		"PRAGMA foreign_keys = ON",
		"PRAGMA busy_timeout = 15000",
		"PRAGMA journal_mode = WAL",
		"PRAGMA synchronous = NORMAL",
	}
	for _, pragma := range pragmas {
		if err := db.Exec(pragma).Error; err != nil {
			return err
		}
	}
	return nil
}
