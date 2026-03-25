mutation {
  sendPickupOrder(
    order: {
      robotName: "FACOBOT", 
      targetNodeAlias: "S3C2L2"
    }
  ) {
    success
    message
    job { 
      uuid 
      status 
    }
  }
}