#Find your public IP by opening <https://ifconfig.me> in your laptop browser, not in the shell.
Set your variables, using your own values:
#export REGION=<ap-south-1>  INSTANCE_TYPE=<t3.micro> STUDENT_ID=<iqbal01> MY_IP=<> EMAIL=<you@example.com>

#How to execute on AWS Console:
   chmod +x *.sh
   ./demo-aws.sh check
   ./demo-aws.sh build
   ./demo-aws.sh wait
   ./demo-aws.sh status

  =======================
   ./demo-aws.sh update      # site becomes v2 (refresh with Ctrl+F5)
   ./demo-aws.sh breakit     # starting v9 fails, the site stays up
   ./demo-aws.sh rollback    # back to v1
  ========================
  ./demo-aws.sh monitor
  ./demo-aws.sh load
