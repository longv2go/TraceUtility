//
//  main.m
//  TraceUtility
//
//  Created by Qusic on 7/9/15.
//  Copyright (c) 2015 Qusic. All rights reserved.
//

#import "InstrumentsPrivateHeader.h"
#import <objc/runtime.h>

#define TUPrint(format, ...) CFShow((__bridge CFStringRef)[NSString stringWithFormat:format, ## __VA_ARGS__])
#define TUIvar(object, name) (__bridge id)*(void **)&((char *)(__bridge void *)object)[ivar_getOffset(class_getInstanceVariable(object_getClass(object), #name))]

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Required. Each instrument is a plugin and we have to load them before we can process their data.
        DVTInitializeSharedFrameworks();
        [DVTDeveloperPaths initializeApplicationDirectoryName:@"Instruments"];
        [XRInternalizedSettingsStore configureWithAdditionalURLs:nil];
        PFTLoadPlugins();

        // Instruments has its own subclass of NSDocumentController without overriding sharedDocumentController method.
        // We have to call this eagerly to make sure the correct document controller is initialized.
        [PFTDocumentController sharedDocumentController];

        // Open a trace document.
        NSString *tracePath = NSProcessInfo.processInfo.arguments[1];
        NSError *error = nil;
        PFTTraceDocument *document = [[PFTTraceDocument alloc]initWithContentsOfURL:[NSURL fileURLWithPath:tracePath] ofType:@"Trace Document" error:&error];
        if (error) {
            TUPrint(@"Error: %@\n", error);
            return 1;
        }
        TUPrint(@"Trace: %@\n", tracePath);

        // List some useful metadata of the document.
        XRDevice *device = document.targetDevice;
        TUPrint(@"Device: %@ (%@ %@ %@)\n", device.deviceDisplayName, device.productType, device.productVersion, device.buildVersion);
        PFTProcess *process = document.defaultProcess;
        TUPrint(@"Process: %@ (%@)\n", process.displayName, process.bundleIdentifier);

        // Each trace document consists of data from several different instruments.
        XRTrace *trace = document.trace;
        for (XRInstrument *instrument in trace.basicInstruments.allInstruments) {
            TUPrint(@"\nInstrument: %@ (%@)\n", instrument.type.name, instrument.type.uuid);

            // Common routine to obtain the data container.
            instrument.viewController = [[XRAnalysisCoreStandardController alloc]initWithInstrument:instrument document:document];
            id<XRInstrumentViewController> controller = instrument.viewController;
            [controller instrumentDidChangeSwitches];
            [controller instrumentChangedTableRequirements];
            id<XRContextContainer> container = controller.detailContextContainer.contextRepresentation.container;

            // Each instrument can have multiple runs.
            NSArray<XRRun *> *runs = instrument.allRuns;
            if (runs.count == 0) {
                TUPrint(@"No data.\n");
                continue;
            }
            for (XRRun *run in runs) {
                TUPrint(@"Run #%@: %@\n", @(run.runNumber), run.displayName);
                instrument.currentRun = run;

                // Different instruments can have different data structure.
                // Here are some straightforward example code demonstrating how to process the data from several commonly used instruments.
                NSString *instrumentID = instrument.type.uuid;
                if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.coresampler2"]) {
                    // Time Profiler: print out all functions in descending order of self execution time.
                    XRCallTreeDetailView *callTreeView = (XRCallTreeDetailView *)container;
                    XRBacktraceRepository *backtraceRepository = callTreeView.backtraceRepository;
                    static NSMutableArray<PFTCallTreeNode *> * (^ const flattenTree)(PFTCallTreeNode *) = ^(PFTCallTreeNode *rootNode) { // Helper function to collect all tree nodes.
                        NSMutableArray *nodes = [NSMutableArray array];
                        if (rootNode) {
                            [nodes addObject:rootNode];
                            for (PFTCallTreeNode *node in rootNode.children) {
                                [nodes addObjectsFromArray:flattenTree(node)];
                            }
                        }
                        return nodes;
                    };
                    
                    static NSMutableArray<PFTCallTreeNode *> * (^const folded_call)(PFTCallTreeNode *) = ^(PFTCallTreeNode *rootNode) {
                        NSMutableArray *nodes = [NSMutableArray array];
                        if (rootNode) {
                            if (!rootNode.children || rootNode.children.count == 0) {
                                [nodes addObject:rootNode];
                            } else {
                                for (PFTCallTreeNode *node in rootNode.children) {
                                    [nodes addObjectsFromArray:folded_call(node)];
                                }
                            }
                        }
                        return nodes;
                    };
                    
                    void (^printf_leaf)(PFTCallTreeNode *) = ^(PFTCallTreeNode *leaf) {
                        NSMutableArray *call_stack = [NSMutableArray array];
                        [call_stack addObject:leaf];
                        
                        PFTCallTreeNode *node = leaf;
                        while (node.parent) {
                            [call_stack insertObject:node.parent atIndex:0];
                            node = node.parent;
                        }
                        
                        for (PFTCallTreeNode *node in call_stack) {
                            if (!node.symbolName || node.symbolName.length == 0) {
                                continue;
                            }
                            printf("%s`%s;", node.libraryName.UTF8String, node.symbolName.UTF8String);
                        }
                        printf("    %i\n",leaf.terminals);
                    };
                    
//                    NSMutableArray<PFTCallTreeNode *> *nodes = flattenTree(backtraceRepository.rootNode);
                    NSMutableArray<PFTCallTreeNode *> *leafs = folded_call(backtraceRepository.rootNode);
                    for (PFTCallTreeNode *leaf in leafs) {
                        printf_leaf(leaf);
                    }
                    
                    
//                    [nodes sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:NSStringFromSelector(@selector(terminals)) ascending:NO]]];
//                    for (PFTCallTreeNode *node in nodes) {
//                        TUPrint(@"%@ %@ %ims\n", node.libraryName, node.symbolName, node.terminals);
//                    }
                } else if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.oa"]) {
                    // Allocations: print out the memory allocated during each second in descending order of the size.
                    XRObjectAllocInstrument *allocInstrument = (XRObjectAllocInstrument *)container;
                    [allocInstrument._topLevelContexts[2] display]; // Four contexts: Statistics, Call Trees, Allocations List, Generations.
                    XRManagedEventArrayController *arrayController = TUIvar(TUIvar(allocInstrument, _objectListController), _ac);
                    NSMutableDictionary<NSNumber *, NSNumber *> *sizeGroupedByTime = [NSMutableDictionary dictionary];
                    for (XRObjectAllocEvent *event in arrayController.arrangedObjects) {
                        NSNumber *time = @(event.timestamp / NSEC_PER_SEC);
                        NSNumber *size = @(sizeGroupedByTime[time].intValue + event.size);
                        sizeGroupedByTime[time] = size;
                    }
                    NSArray<NSNumber *> *sortedTime = [sizeGroupedByTime.allKeys sortedArrayUsingComparator:^(NSNumber *time1, NSNumber *time2) {
                        return [sizeGroupedByTime[time2] compare:sizeGroupedByTime[time1]];
                    }];
                    for (NSNumber *time in sortedTime) {
                        TUPrint(@"#%@ %@Bytes\n", time, sizeGroupedByTime[time]);
                    }
                } else if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.coreanimation"]) {
                    // Core Animation:
                } else if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.networking"]) {
                    // Connections:
                } else if ([instrumentID isEqualToString:@"com.apple.xray.power.mobile.energy"]) {
                    // Energy Usage Log:
                } else {
                    TUPrint(@"Data processor has not been implemented for this type of instrument.\n");
                }
            }
        }

        // Close the document safely.
        [document close];
    }
    return 0;
}
