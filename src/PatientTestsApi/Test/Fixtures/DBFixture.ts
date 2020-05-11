import { PatientFixture } from "./PatientFixture";
import { Db, MongoClient } from "mongodb";
import { ISettings } from "../../Models/ISettings";
import { ICollection } from "../../Services/ICollection";
import { FileSettings } from "./FileSettings";

export class DBFixture {
  
  public mongoDb: Db;
  public mongoClient: MongoClient;
  public settings: ISettings;

  constructor(){
    this.mongoDb = {} as Db;
    this.mongoClient = {} as MongoClient; 
    this.settings = new FileSettings();
  }

  public async init(): Promise<void> {

    // connect and select database
    this.mongoClient = await MongoClient.connect(this.settings.mongoConnectionString,
      { useUnifiedTopology: true, useNewUrlParser: true, tlsAllowInvalidCertificates: true });
    
    this.mongoDb = this.mongoClient.db(this.settings.patientTestDatabase);
  }

  public createPatientCollection(): ICollection {
    return this.mongoDb.collection(this.settings.patientCollection);
  }

  public async cleanPatients(): Promise<void> {
    await this.mongoDb.collection(this.settings.patientCollection)
        .deleteOne({ _id: PatientFixture.CreatePatientId, _shardKey: PatientFixture.CreatePatientId });
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  public async loadPatient(id: string): Promise<any> {
    return await this.mongoDb.collection(this.settings.patientCollection).findOne({_id: id});
  }

}