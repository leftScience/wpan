package cmd

import (
	"fmt"
	"ohome/conf"
	"ohome/discovery"
	"ohome/global"
	"ohome/router"
	"ohome/service"
	"ohome/task"
)

func Start() {
	// 阶段标记：真机上起不来时，看日志最后出现的 [stage] 就知道死在哪一步
	fmt.Println("[stage] conf.InitConfig")
	conf.InitConfig()
	fmt.Println("[stage] conf.InitLogger")
	global.Logger = conf.InitLogger()

	fmt.Println("[stage] discovery.Initialize")
	discoveryManager, err := discovery.Initialize()
	if err != nil {
		// mDNS 只是发现便利，手机上组播/私有目录受限时不该带崩整个服务端
		fmt.Println("[stage] discovery.Initialize failed, continue without mDNS: " + err.Error())
		if global.Logger != nil {
			global.Logger.Warnf("discovery.Initialize failed, continue without mDNS: %s", err.Error())
		}
		discoveryManager = nil
	}
	discovery.Default = discoveryManager

	if discoveryManager != nil {
		discoveryPublisher, pubErr := discovery.NewPublisher(discoveryManager)
		if pubErr != nil {
			if global.Logger != nil {
				global.Logger.Warnf("Start mDNS publisher failed: %s", pubErr.Error())
			}
		} else {
			defer discoveryPublisher.Shutdown()
		}
	}

	fmt.Println("[stage] conf.InitDB")
	//初始化db
	db, err := conf.InitDB()
	if err != nil {
		panic(err.Error())
	}
	global.DB = db

	var quarkTransferTaskService service.QuarkTransferTaskService
	if err := quarkTransferTaskService.RecoverInterruptedTasks(); err != nil && global.Logger != nil {
		global.Logger.Errorf("Recover Quark Transfer Task Error: %s", err.Error())
	}
	service.EnsureQuarkTransferTaskExecutor()

	task.StartDoubanSyncScheduler()
	task.StartQuarkAutoSaveScheduler()

	fmt.Println("[stage] router.InitRouter")
	router.InitRouter()
}
