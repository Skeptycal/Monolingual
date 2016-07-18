/*
*  Copyright (C) 2001, 2002  Joshua Schrier (jschrier@mac.com),
*                2004-2016 Ingmar Stein
*  Released under the GNU GPL.  For more information, see the header file.
*/
//
//  MainViewController.swift
//  Monolingual
//
//  Created by Ingmar Stein on 13.07.14.
//
//

import Cocoa

enum MonolingualMode: Int {
	case Languages = 0
	case Architectures
}

struct ArchitectureInfo {
	let name: String
	let displayName: String
	let cpuType: cpu_type_t
	let cpuSubtype: cpu_subtype_t
}

// these defines are not (yet) visible to Swift
// swiftlint:disable variable_name
let CPU_TYPE_X86_64: cpu_type_t				    = CPU_TYPE_X86 | CPU_ARCH_ABI64
let CPU_TYPE_ARM64: cpu_type_t					= CPU_TYPE_ARM | CPU_ARCH_ABI64
let CPU_TYPE_POWERPC64: cpu_type_t				= CPU_TYPE_POWERPC | CPU_ARCH_ABI64
// swiftlint:enable variable_name

func mach_task_self() -> mach_port_t {
	return mach_task_self_
}

final class MainViewController: NSViewController, ProgressViewControllerDelegate, ProgressProtocol {

	@IBOutlet private weak var currentArchitecture: NSTextField!

	private var progressViewController: ProgressViewController?

	private var blacklist: [BlacklistEntry]?
	dynamic var languages: [LanguageSetting]!
	dynamic var architectures: [ArchitectureSetting]!

	private var mode: MonolingualMode = .Languages
	private var processApplication: Root?
	private var processApplicationObserver: NSObjectProtocol?
	private var helperConnection: NSXPCConnection?
	private var progress: Progress?

	private let sipProtectedLocations = [ "/System", "/bin" ]

	private lazy var xpcServiceConnection: NSXPCConnection = {
		let connection = NSXPCConnection(serviceName: "com.github.IngmarStein.Monolingual.XPCService")
		connection.remoteObjectInterface = NSXPCInterface(with: XPCServiceProtocol.self)
		connection.resume()
		return connection
	}()

	private var roots: [Root] {
		if let application = self.processApplication {
			return [ application ]
		} else {
			let pref = UserDefaults.standard.array(forKey: "Roots") as? [[String : AnyObject]]
			return pref?.map { Root(dictionary: $0) } ?? [Root]()
		}
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}

	private func finishProcessing() {
		progressDidEnd(completed: true)
	}

	@IBAction func removeLanguages(_ sender: AnyObject) {
		// Display a warning first
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
		alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
		alert.messageText = NSLocalizedString("Are you sure you want to remove these languages? You will not be able to restore them without reinstalling macOS.", comment: "")
		alert.beginSheetModal(for: self.view.window!) { responseCode in
			if NSAlertSecondButtonReturn == responseCode {
				self.checkAndRemove()
			}
		}
	}

	@IBAction func removeArchitectures(_ sender: AnyObject) {
		self.mode = .Architectures

		log.open()

		let now = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
		log.message("Monolingual started at \(now)\nRemoving architectures: ")

		let archs = self.architectures.filter { $0.enabled } .map { $0.name }
		for arch in archs {
			log.message(" \(arch)")
		}

		log.message("\nModified files:\n")

		let num_archs = archs.count
		if num_archs == self.architectures.count {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("Removing all architectures will make macOS inoperable. Please keep at least one architecture and try again.", comment: "")
			alert.beginSheetModal(for: self.view.window!, completionHandler: nil)
			//NSLocalizedString("Cannot remove all architectures", "")
			log.close()
		} else if num_archs > 0 {
			// start things off if we have something to remove!
			let roots = self.roots

			let request = HelperRequest()
			request.doStrip = UserDefaults.standard.bool(forKey: "Strip")
			request.bundleBlacklist = Set<String>(self.blacklist!.filter { $0.architectures } .map { $0.bundle })
			request.includes = roots.filter { $0.architectures } .map { $0.path }
			request.excludes = roots.filter { !$0.architectures } .map { $0.path } + sipProtectedLocations
			request.thin = archs

			for item in request.bundleBlacklist! {
				os_log_info(OS_LOG_DEFAULT, "Blacklisting \(item)")
			}
			for include in request.includes! {
				os_log_info(OS_LOG_DEFAULT, "Adding root \(include)")
			}
			for exclude in request.excludes! {
				os_log_info(OS_LOG_DEFAULT, "Excluding root \(exclude)")
			}

			self.checkAndRunHelper(arguments: request)
		} else {
			log.close()
		}
	}

	func processed(file: String, size: Int, appName: String?) {
		if let progress = self.progress {
			let count = progress.userInfo[.fileCompletedCountKey] as? Int ?? 0
			progress.setUserInfoObject((count + 1) as NSNumber, forKey: .fileCompletedCountKey)
			progress.setUserInfoObject(URL(fileURLWithPath: file), forKey: .fileURLKey)
			progress.setUserInfoObject(size as NSNumber, forKey: ProgressUserInfoKey("sizeDifference"))
			if let appName = appName {
				progress.setUserInfoObject(appName as NSString, forKey: ProgressUserInfoKey("appName"))
			}
			progress.completedUnitCount += size
		}
	}

	override func observeValue(forKeyPath keyPath: String?, of object: AnyObject?, change: [NSKeyValueChangeKey : AnyObject]?, context: UnsafeMutablePointer<Void>?) {
		if keyPath == "completedUnitCount" {
			if let progress = object as? Progress, let url = progress.userInfo[.fileURLKey] as? URL, let size = progress.userInfo[ProgressUserInfoKey("sizeDifference")] as? Int {
				processProgress(file: url, size:size, appName:progress.userInfo[ProgressUserInfoKey("appName")] as? String)
			}
		}
	}

	private func processProgress(file: URL, size: Int, appName: String?) {
		log.message("\(file.path!): \(size)\n")

		let message: String
		if self.mode == .Architectures {
			message = NSLocalizedString("Removing architecture from universal binary", comment: "")
		} else {
			// parse file name
			var lang: String?

			if self.mode == .Languages {
				for pathComponent in file.pathComponents! {
					if (pathComponent as NSString).pathExtension == "lproj" {
						for language in self.languages {
							if language.folders.contains(pathComponent) {
								lang = language.displayName
								break
							}
						}
					}
				}
			}
			if let app = appName, let lang = lang {
				message = String(format: NSLocalizedString("Removing language %@ from %@…", comment: ""), lang as NSString, app as NSString)
			} else if let lang = lang {
				message = String(format: NSLocalizedString("Removing language %@…", comment: ""), lang as NSString)
			} else {
				message = String(format: NSLocalizedString("Removing %@…", comment: ""), file)
			}
		}

		DispatchQueue.main.async {
			if let viewController = self.progressViewController, let path = file.path {
				viewController.text = message
				viewController.file = path
				NSApp.setWindowsNeedUpdate(true)
			}
		}
	}

	func installHelper(reply: (Bool) -> Void) {
		let xpcService = self.xpcServiceConnection.remoteObjectProxyWithErrorHandler() { error -> Void in
			os_log_error(OS_LOG_DEFAULT, "XPCService error: %@", error)
		} as? XPCServiceProtocol

		if let xpcService = xpcService {
			xpcService.installHelperTool { error in
				if let error = error {
					DispatchQueue.main.async {
						let alert = NSAlert()
						alert.alertStyle = .critical
						alert.messageText = error.localizedDescription
						alert.beginSheetModal(for: self.view.window!, completionHandler: nil)
						log.close()
					}
					reply(false)
				} else {
					reply(true)
				}
			}
		}
	}

	private func runHelper(arguments: HelperRequest) {
		ProcessInfo.processInfo.disableSuddenTermination()

		let progress = Progress(totalUnitCount: -1)
		progress.becomeCurrent(withPendingUnitCount: -1)
		progress.addObserver(self, forKeyPath: "completedUnitCount", options: .new, context: nil)

		// DEBUG
		//arguments.dryRun = true

		let helper = helperConnection!.remoteObjectProxyWithErrorHandler() { error in
			os_log_error(OS_LOG_DEFAULT, "Error communicating with helper: %@", error)
			DispatchQueue.main.async {
				self.finishProcessing()
			}
		} as! HelperProtocol

		helper.processRequest(arguments, progress:self) { exitCode in
			os_log_info(OS_LOG_DEFAULT, "helper finished with exit code: \(exitCode)")
			helper.exitWithCode(exitCode)
			if exitCode == Int(EXIT_SUCCESS) {
				DispatchQueue.main.async {
					self.finishProcessing()
				}
			}
		}

		progress.resignCurrent()
		self.progress = progress

		if self.progressViewController == nil {
			let storyboard = NSStoryboard(name: "Main", bundle: nil)
			self.progressViewController = storyboard.instantiateController(withIdentifier: "ProgressViewController") as? ProgressViewController
		}
		self.progressViewController?.delegate = self
		if self.progressViewController!.presenting == nil {
			presentViewControllerAsSheet(self.progressViewController!)
		}

		let notification = NSUserNotification()
		notification.title = NSLocalizedString("Monolingual started", comment: "")
		notification.informativeText = NSLocalizedString("Started removing files", comment: "")

		NSUserNotificationCenter.default.deliver(notification)
	}

	private func checkAndRunHelper(arguments: HelperRequest) {
		let xpcService = self.xpcServiceConnection.remoteObjectProxyWithErrorHandler() { error -> Void in
			os_log_error(OS_LOG_DEFAULT, "XPCService error: %@", error)
		} as? XPCServiceProtocol

		if let xpcService = xpcService {
			xpcService.connect() { endpoint -> Void in
				if let endpoint = endpoint {
					var performInstallation = false
					let connection = NSXPCConnection(listenerEndpoint: endpoint)
					let interface = NSXPCInterface(with: HelperProtocol.self)
					interface.setInterface(NSXPCInterface(with: ProgressProtocol.self), for: #selector(HelperProtocol.processRequest(_:progress:reply:)), argumentIndex: 1, ofReply: false)
					connection.remoteObjectInterface = interface
					connection.invalidationHandler = {
						os_log_error(OS_LOG_DEFAULT, "XPC connection to helper invalidated.")
						self.helperConnection = nil
						if performInstallation {
							self.installHelper() { success in
								if success {
									self.checkAndRunHelper(arguments: arguments)
								}
							}
						}
					}
					connection.resume()
					self.helperConnection = connection

					if let connection = self.helperConnection {
						let helper = connection.remoteObjectProxyWithErrorHandler() { error in
							os_log_error(OS_LOG_DEFAULT, "Error connecting to helper: %@", error)
						} as! HelperProtocol

						helper.getVersionWithReply() { installedVersion in
							xpcService.bundledHelperVersion() { bundledVersion in
								if installedVersion == bundledVersion {
									// helper is current
									DispatchQueue.main.async {
										self.runHelper(arguments: arguments)
									}
								} else {
									// helper is different version
									performInstallation = true
									helper.uninstall()
									helper.exitWithCode(Int(EXIT_SUCCESS))
									connection.invalidate()
								}
							}
						}
					}
				} else {
					os_log_error(OS_LOG_DEFAULT, "Failed to get XPC endpoint.")
					self.installHelper() { success in
						if success {
							self.checkAndRunHelper(arguments: arguments)
						}
					}
				}
			}
		}
	}

	func progressViewControllerDidCancel(_ progressViewController: ProgressViewController) {
		progressDidEnd(completed: false)
	}

	private func progressDidEnd(completed: Bool) {
		if self.progress == nil {
			return
		}

		self.processApplication = nil
		self.dismiss(self.progressViewController!)

		let progress = self.progress!
		let byteCount = ByteCountFormatter.string(fromByteCount: max(progress.completedUnitCount, 0), countStyle: .file)
		self.progress = nil

		if !completed {
			// cancel the current progress which tells the helper to stop
			progress.cancel()
			os_log_debug(OS_LOG_DEFAULT, "Closing progress connection")

			if let helper = self.helperConnection?.remoteObjectProxy as? HelperProtocol {
				helper.exitWithCode(Int(EXIT_FAILURE))
			}

			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = String(format: NSLocalizedString("You cancelled the removal. Some files were erased, some were not. Space saved: %@.", comment: ""), byteCount as NSString)
			//alert.informativeText = NSLocalizedString("Removal cancelled", "")
			alert.beginSheetModal(for: self.view.window!, completionHandler: nil)
		} else {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = String(format: NSLocalizedString("Files removed. Space saved: %@.", comment: ""), byteCount as NSString)
			//alert.informativeText = NSBeginAlertSheet(NSLocalizedString("Removal completed", comment: "")
			alert.beginSheetModal(for: self.view.window!, completionHandler: nil)

			let notification = NSUserNotification()
			notification.title = NSLocalizedString("Monolingual finished", comment: "")
			notification.informativeText = NSLocalizedString("Finished removing files", comment: "")

			NSUserNotificationCenter.default.deliver(notification)
		}

		if let connection = self.helperConnection {
			os_log_info(OS_LOG_DEFAULT, "Closing connection to helper")
			connection.invalidate()
			self.helperConnection = nil
		}

		log.close()

		ProcessInfo.processInfo.enableSuddenTermination()
	}

	private func checkAndRemove() {
		if checkRoots() && checkLanguages() {
			doRemoveLanguages()
		}
	}

	private func checkRoots() -> Bool {
		var languageEnabled = false
		let roots = self.roots
		for root in roots {
			if root.languages {
				languageEnabled = true
				break
			}
		}

		if !languageEnabled {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("Monolingual is stopping without making any changes. Your OS has not been modified.", comment: "")
			alert.beginSheetModal(for: self.view.window!, completionHandler: nil)
			//NSLocalizedString("Nothing done", comment: "")
		}

		return languageEnabled
	}

	private func checkLanguages() -> Bool {
		var englishChecked = false
		for language in self.languages {
			if language.enabled && language.folders[0] == "en.lproj" {
				englishChecked = true
				break
			}
		}

		if englishChecked {
			// Display a warning
			let alert = NSAlert()
			alert.alertStyle = .critical
			alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
			alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
			alert.messageText = NSLocalizedString("You are about to delete the English language files. Are you sure you want to do that?", comment: "")

			alert.beginSheetModal(for: self.view.window!) { response in
				if response == NSAlertSecondButtonReturn {
					self.doRemoveLanguages()
				}
			}
		}

		return !englishChecked
	}

	private func doRemoveLanguages() {
		self.mode = .Languages

		log.open()
		let now = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
		log.message("Monolingual started at \(now)\nRemoving languages: ")

		let roots = self.roots

		let includes = roots.filter { $0.languages } .map { $0.path }
		let excludes = roots.filter { !$0.languages } .map { $0.path } + sipProtectedLocations
		let bl = self.blacklist!.filter { $0.languages } .map { $0.bundle }

		for item in bl {
			os_log_info(OS_LOG_DEFAULT, "Blacklisting \(item)")
		}
		for include in includes {
			os_log_info(OS_LOG_DEFAULT, "Adding root \(include)")
		}
		for exclude in excludes {
			os_log_info(OS_LOG_DEFAULT, "Excluding root \(exclude)")
		}

		var rCount = 0
		var folders = Set<String>()
		for language in self.languages {
			if language.enabled {
				for path in language.folders {
					folders.insert(path)
					if rCount != 0 {
						log.message(" ")
					}
					log.message(path)
					rCount += 1
				}
			}
		}
		if UserDefaults.standard.bool(forKey: "NIB") {
			folders.insert("designable.nib")
		}

		log.message("\nDeleted files: \n")
		if rCount == self.languages.count {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("Cannot remove all languages", comment: "")
			alert.informativeText = NSLocalizedString("Removing all languages will make macOS inoperable. Please keep at least one language and try again.", comment: "")
			alert.beginSheetModal(for: self.view.window!, completionHandler: nil)
			log.close()
		} else if rCount > 0 {
			// start things off if we have something to remove!

			let request = HelperRequest()
			request.trash = UserDefaults.standard.bool(forKey: "Trash")
			request.uid = getuid()
			request.bundleBlacklist = Set<String>(bl)
			request.includes = includes
			request.excludes = excludes
			request.directories = folders

			checkAndRunHelper(arguments: request)
		} else {
			log.close()
		}
	}

	override func viewDidLoad() {
		let currentLocale = Locale.current

		// never check the user's preferred languages, English the the user's locale be default
		let userLanguages = Set<String>((Locale.preferredLanguages).map {
			return $0.replacingOccurrences(of: "-", with:"_")
		} + ["en", currentLocale.localeIdentifier])

		let availableLocalizations = Set<String>((Locale.availableLocaleIdentifiers)
			// add some known locales not contained in availableLocaleIdentifiers
			+ ["ach", "an", "ast", "ay", "bi", "co", "fur", "gd", "gn", "ia", "jv", "ku", "la", "mi", "md", "no", "oc", "qu", "sa", "sd", "se", "su", "tet", "tk_Cyrl", "tl", "tlh", "tt", "wa", "yi", "zh_CN", "zh_TW" ])

		let systemLocale = Locale(localeIdentifier: "en_US_POSIX")
		self.languages = [String](availableLocalizations).map { (localeIdentifier) -> LanguageSetting in
			var folders = ["\(localeIdentifier).lproj"]
			let components = Locale.components(fromLocaleIdentifier: localeIdentifier)
			if let language = components[Locale.Key.languageCode.rawValue], let country = components[Locale.Key.countryCode.rawValue] {
				folders.append("\(language)-\(country).lproj")
				folders.append("\(language)_\(country).lproj")
			} else if let displayName = systemLocale.displayName(forKey: Locale.Key.identifier, value: localeIdentifier as NSString) {
				folders.append("\(displayName).lproj")
			}
			let displayName = currentLocale.displayName(forKey: Locale.Key.identifier, value: localeIdentifier as NSString) ?? NSLocalizedString("locale_\(localeIdentifier)", comment: "")
			return LanguageSetting(enabled: !userLanguages.contains(localeIdentifier), folders: folders, displayName: displayName)
		}.sorted { $0.displayName < $1.displayName }

		// swiftlint:disable comma
		let archs = [
			ArchitectureInfo(name:"arm",       displayName:"ARM",                    cpuType: CPU_TYPE_ARM,       cpuSubtype: CPU_SUBTYPE_ARM_ALL),
			ArchitectureInfo(name:"ppc",       displayName:"PowerPC",                cpuType: CPU_TYPE_POWERPC,   cpuSubtype: CPU_SUBTYPE_POWERPC_ALL),
			ArchitectureInfo(name:"ppc750",    displayName:"PowerPC G3",             cpuType: CPU_TYPE_POWERPC,   cpuSubtype: CPU_SUBTYPE_POWERPC_750),
			ArchitectureInfo(name:"ppc7400",   displayName:"PowerPC G4",             cpuType: CPU_TYPE_POWERPC,   cpuSubtype: CPU_SUBTYPE_POWERPC_7400),
			ArchitectureInfo(name:"ppc7450",   displayName:"PowerPC G4+",            cpuType: CPU_TYPE_POWERPC,   cpuSubtype: CPU_SUBTYPE_POWERPC_7450),
			ArchitectureInfo(name:"ppc970",    displayName:"PowerPC G5",             cpuType: CPU_TYPE_POWERPC,   cpuSubtype: CPU_SUBTYPE_POWERPC_970),
			ArchitectureInfo(name:"ppc64",     displayName:"PowerPC 64-bit",         cpuType: CPU_TYPE_POWERPC64, cpuSubtype: CPU_SUBTYPE_POWERPC_ALL),
			ArchitectureInfo(name:"ppc970-64", displayName:"PowerPC G5 64-bit",      cpuType: CPU_TYPE_POWERPC64, cpuSubtype: CPU_SUBTYPE_POWERPC_970),
			ArchitectureInfo(name:"x86",       displayName:"Intel 32-bit",           cpuType: CPU_TYPE_X86,       cpuSubtype: CPU_SUBTYPE_X86_ALL),
			ArchitectureInfo(name:"x86_64",    displayName:"Intel 64-bit",           cpuType: CPU_TYPE_X86_64,    cpuSubtype: CPU_SUBTYPE_X86_64_ALL),
			ArchitectureInfo(name:"x86_64h",   displayName:"Intel 64-bit (Haswell)", cpuType: CPU_TYPE_X86_64,    cpuSubtype: CPU_SUBTYPE_X86_64_H)
		]
		// swiftlint:enable comma

		var infoCount = mach_msg_type_number_t(sizeof(host_basic_info_data_t.self) / sizeof(integer_t.self)) // HOST_BASIC_INFO_COUNT
		var hostInfo = host_basic_info_data_t(max_cpus: 0, avail_cpus: 0, memory_size: 0, cpu_type: 0, cpu_subtype: 0, cpu_threadtype: 0, physical_cpu: 0, physical_cpu_max: 0, logical_cpu: 0, logical_cpu_max: 0, max_mem: 0)
		let my_mach_host_self = mach_host_self()
		let ret = withUnsafeMutablePointer(&hostInfo) {
			(pointer: UnsafeMutablePointer<host_basic_info_data_t>) in
			host_info(my_mach_host_self, HOST_BASIC_INFO, UnsafeMutablePointer<integer_t>(pointer), &infoCount)
		}
		mach_port_deallocate(mach_task_self(), my_mach_host_self)

		if hostInfo.cpu_type == CPU_TYPE_X86 {
			// fix host_info
			var x86_64: Int = 0
			var x86_64_size = Int(sizeof(Int.self))
			let ret = sysctlbyname("hw.optional.x86_64", &x86_64, &x86_64_size, nil, 0)
			if ret == 0 {
				if x86_64 != 0 {
					hostInfo = host_basic_info_data_t(
						max_cpus: hostInfo.max_cpus,
						avail_cpus: hostInfo.avail_cpus,
						memory_size: hostInfo.memory_size,
						cpu_type: CPU_TYPE_X86_64,
						cpu_subtype: (hostInfo.cpu_subtype == CPU_SUBTYPE_X86_64_H) ? CPU_SUBTYPE_X86_64_H : CPU_SUBTYPE_X86_64_ALL,
						cpu_threadtype: hostInfo.cpu_threadtype,
						physical_cpu: hostInfo.physical_cpu,
						physical_cpu_max: hostInfo.physical_cpu_max,
						logical_cpu: hostInfo.logical_cpu,
						logical_cpu_max: hostInfo.logical_cpu_max,
						max_mem: hostInfo.max_mem)
				}
			}
		}

		self.currentArchitecture.stringValue = NSLocalizedString("unknown", comment: "")

		self.architectures = archs.map { arch in
			let enabled = (ret == KERN_SUCCESS && hostInfo.cpu_type != arch.cpuType)
			let architecture = ArchitectureSetting(enabled: enabled, name: arch.name, displayName: arch.displayName)
			if hostInfo.cpu_type == arch.cpuType && hostInfo.cpu_subtype == arch.cpuSubtype {
				self.currentArchitecture.stringValue = String(format: NSLocalizedString("Current architecture: %@", comment: ""), arch.displayName as NSString)
			}
			return architecture
		}

		// load blacklist from bundle
		if let blacklistBundle = Bundle.main.urlForResource("blacklist", withExtension:"plist"), let entries = NSArray(contentsOf: blacklistBundle) as? [[NSObject:AnyObject]] {
			self.blacklist = entries.map { BlacklistEntry(dictionary: $0) }
		}
		// load remote blacklist asynchronously
		DispatchQueue.main.async {
			if let blacklistURL = URL(string:"https://ingmarstein.github.io/Monolingual/blacklist.plist"), let entries = NSArray(contentsOf: blacklistURL) as? [[NSObject:AnyObject]] {
				self.blacklist = entries.map { BlacklistEntry(dictionary: $0) }
			}
		}

		self.processApplicationObserver = NotificationCenter.default.addObserver(forName: processApplicationNotification, object: nil, queue: nil) { notification in
			self.processApplication = Root(dictionary: notification.userInfo!)
		}
	}

	deinit {
		if let observer = self.processApplicationObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		xpcServiceConnection.invalidate()
	}

}
