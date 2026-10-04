const std=@import("std");const scheduler=@import("scheduler");
pub fn main()!void{
 const a=std.heap.page_allocator;const args=try std.process.argsAlloc(a);
 const job:scheduler.Job=.{.kind=.reminders,.config_dir=args[2],.storage=args[3]};
 if(std.mem.eql(u8,args[1],"enable"))try scheduler.enableOn(a,job,.linux)
 else if(std.mem.eql(u8,args[1],"disable"))try scheduler.disableOn(a,job,.linux)
 else return error.UnknownCommand;
}
